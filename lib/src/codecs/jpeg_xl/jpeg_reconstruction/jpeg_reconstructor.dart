import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_coefficient_sink.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_reconstruction_data.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_reconstruction_data_decoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_writer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_global.dart';

/// Reconstructs the original JPEG bytes from a decoded JPEG XL [frame].
/// The frame must have captured JPEG coefficients during decoding. Baseline
/// grayscale and YCbCr transcodes are supported; incompatible transform or
/// progressive-scan data throws [JpegXlUnsupportedException].
Uint8List reconstructJpegFromFrame(Frame frame, Uint8List reconstructionPayload) {
  final JpegReconstructionData reconstructionData = decodeJpegReconstructionData(reconstructionPayload);
  final JpegCoefficientSink? coefficientSink = frame.jpegCoefficientSink;
  final HighFrequencyGlobal? highFrequencyGlobal = frame.highFrequencyGlobal;
  if (coefficientSink == null || highFrequencyGlobal == null) {
    throw JpegXlUnsupportedException(feature: 'jpeg-reconstruction-non-vardct');
  }
  if (frame.passes.length != 1) {
    throw JpegXlUnsupportedException(feature: 'jpeg-reconstruction-multipass');
  }
  if (coefficientSink.containsNonDct8) {
    // Only 8x8 DCT blocks map to JPEG; a crafted stream might use others.
    throw JpegXlUnsupportedException(feature: 'jpeg-reconstruction-nondct8');
  }

  reconstructionData.width = frame.globalMetadata.size.width;
  reconstructionData.height = frame.globalMetadata.size.height;

  final FrameHeader header = frame.header;
  int maximumHorizontalUpsamplingShift = 0;
  int maximumVerticalUpsamplingShift = 0;
  for (int channelIndex = 0; channelIndex < 3; channelIndex++) {
    if (header.jpegHorizontalUpsamplingShift[channelIndex] > maximumHorizontalUpsamplingShift) {
      maximumHorizontalUpsamplingShift = header.jpegHorizontalUpsamplingShift[channelIndex];
    }
    if (header.jpegVerticalUpsamplingShift[channelIndex] > maximumVerticalUpsamplingShift) {
      maximumVerticalUpsamplingShift = header.jpegVerticalUpsamplingShift[channelIndex];
    }
  }
  final bool subsampled = maximumHorizontalUpsamplingShift != 0 || maximumVerticalUpsamplingShift != 0;
  if (reconstructionData.components.length > 1 && !header.usesYcbcr) {
    // RGB (kNone) transcodes carry a DC level-shift (dcoff) not yet handled.
    throw JpegXlUnsupportedException(feature: 'jpeg-reconstruction-rgb');
  }

  // Quantization-table values come from raw DCT8x8 matrices in semantic
  // X, Y, B channel order.
  final List<List<double>>? rawQuantizationWeights = highFrequencyGlobal.quantizationParameters[0].quantizationWeights;
  if (rawQuantizationWeights == null) {
    throw JpegXlUnsupportedException(feature: 'jpeg-reconstruction-nonraw-quantization');
  }
  for (int tableIndex = 0; tableIndex < reconstructionData.quantizationTables.length; tableIndex++) {
    final int matchingComponentIndex = reconstructionData.components.indexWhere((component) => component.quantizationTableIndex == tableIndex);
    final int componentIndex = matchingComponentIndex < 0 ? 0 : matchingComponentIndex;
    // JPEG XL stores the raw matrix transposed relative to JPEG's row-major layout.
    final List<double> table = rawQuantizationWeights[colorChannelOrder[componentIndex]];
    for (int row = 0; row < 8; row++) {
      for (int column = 0; column < 8; column++) {
        reconstructionData.quantizationTables[tableIndex].values[row * 8 + column] = table[column * 8 + row].toInt();
      }
    }
  }

  for (int componentIndex = 0; componentIndex < reconstructionData.components.length; componentIndex++) {
    final JpegComponent component = reconstructionData.components[componentIndex];
    final int channelIndex = colorChannelOrder[componentIndex];
    component.horizontalSamplingFactor = (1 << maximumHorizontalUpsamplingShift) >> header.jpegHorizontalUpsamplingShift[channelIndex];
    component.verticalSamplingFactor = (1 << maximumVerticalUpsamplingShift) >> header.jpegVerticalUpsamplingShift[channelIndex];
    component.widthInBlocks = coefficientSink.widthInBlocks[componentIndex];
    component.heightInBlocks = coefficientSink.heightInBlocks[componentIndex];
    component.coefficients = coefficientSink.coefficients[componentIndex];
  }

  // Chroma-from-luma inversion. In 4:4:4 YCbCr, the stored chroma AC is a CfL
  // residual; add back the luma contribution exactly as libjxl's
  // reconstruction path does (fixed-point, kCFLFixedPointPrecision = 11,
  // color factor 84). Subsampled chroma carries no CfL, and luma never does.
  if (reconstructionData.components.length == 3 && !subsampled) {
    final Int32List lumaQuantizationTable = reconstructionData.quantizationTables[reconstructionData.components[0].quantizationTableIndex].values;
    final Int32List lumaCoefficients = coefficientSink.coefficients[0];
    for (final int componentIndex in const [1, 2]) {
      _restoreChromaFromLuma(
        coefficientSink.coefficients[componentIndex],
        lumaCoefficients,
        coefficientSink.chromaFromLumaFactors[componentIndex],
        reconstructionData.quantizationTables[reconstructionData.components[componentIndex].quantizationTableIndex].values,
        lumaQuantizationTable,
      );
    }
  }

  // Robustness: JPEG coefficients must fit JPEG's range (DC clamped to
  // +/-2047, AC in +/-4095), matching libjxl's reconstruction guard. Valid
  // transcodes always satisfy this (so it is byte-exact-invariant); a crafted
  // `.jxl` with an out-of-range coefficient is rejected here instead of
  // overflowing the entropy writer's Huffman-symbol index.
  for (final JpegComponent component in reconstructionData.components) {
    final Int32List coefficients = component.coefficients;
    for (int blockOffset = 0; blockOffset < coefficients.length; blockOffset += jpegDctBlockCoefficientCount) {
      final int dcCoefficient = coefficients[blockOffset];
      coefficients[blockOffset] = dcCoefficient < -2047
          ? -2047
          : dcCoefficient > 2047
          ? 2047
          : dcCoefficient;
      for (int coefficientIndex = 1; coefficientIndex < jpegDctBlockCoefficientCount; coefficientIndex++) {
        if (coefficients[blockOffset + coefficientIndex] < -4095 || coefficients[blockOffset + coefficientIndex] > 4095) {
          throw const JpegXlInvalidBitstreamException(message: 'JPEG DCT coefficient out of range');
        }
      }
    }
  }

  return writeJpeg(reconstructionData);
}

/// Fixed-point precision used for chroma-from-luma reconstruction.
const int _chromaFromLumaPrecision = 11;

/// Rounding offset for [_chromaFromLumaPrecision]-bit fixed-point products.
const int _chromaFromLumaRoundingOffset = 1 << (_chromaFromLumaPrecision - 1);

/// JPEG XL color-factor denominator used by chroma-from-luma.
const int _colorFactor = 84;

/// Restores the luma contribution in [chromaCoefficients].
/// DC coefficients remain unchanged. AC coefficients use the fixed-point
/// formula from libjxl's JPEG reconstruction path.
void _restoreChromaFromLuma(
  Int32List chromaCoefficients,
  Int32List lumaCoefficients,
  Int32List factors,
  Int32List chromaQuantizationTable,
  Int32List lumaQuantizationTable,
) {
  final Int32List scaledQuantization = Int32List(jpegDctBlockCoefficientCount);
  for (int coefficientIndex = 1; coefficientIndex < jpegDctBlockCoefficientCount; coefficientIndex++) {
    scaledQuantization[coefficientIndex] = (lumaQuantizationTable[coefficientIndex] << _chromaFromLumaPrecision) ~/ chromaQuantizationTable[coefficientIndex];
  }
  for (int blockIndex = 0; blockIndex < factors.length; blockIndex++) {
    final int factor = factors[blockIndex];
    if (factor == 0) {
      continue; // ratio 0 -> no contribution.
    }
    final int ratio = (factor << _chromaFromLumaPrecision) ~/ _colorFactor;
    final int blockOffset = blockIndex * jpegDctBlockCoefficientCount;
    for (int coefficientIndex = 1; coefficientIndex < jpegDctBlockCoefficientCount; coefficientIndex++) {
      final int coefficientScale = (scaledQuantization[coefficientIndex] * ratio + _chromaFromLumaRoundingOffset) >> _chromaFromLumaPrecision;
      chromaCoefficients[blockOffset + coefficientIndex] += (lumaCoefficients[blockOffset + coefficientIndex] * coefficientScale + _chromaFromLumaRoundingOffset) >> _chromaFromLumaPrecision;
    }
  }
}
