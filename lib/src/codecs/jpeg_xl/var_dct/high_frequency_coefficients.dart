import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/opsin_inverse.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/low_frequency_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_coefficient_sink.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/dct.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_block_context.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_global.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_metadata.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_pass.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/low_frequency_channel_correlation.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Maps coefficient positions to high-frequency entropy contexts.
const _coeffFreqCtx = <int>[
  // Index 0 is unused.
  -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, //
  15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, //
  23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26, //
  27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
];

/// Maps nonzero-coefficient counts to entropy contexts.
const _coeffNumNonzeroCtx = <int>[
  // Index 0 is unused.
  -1, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123, 152, 152, //
  152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180, 180, 180, //
  180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206, 206, 206, //
  206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, //
  206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
];

/// Decodes and dequantizes high-frequency coefficients for one pass group.
final class HighFrequencyCoefficients {
  /// Frame that owns this coefficient group.
  final Frame frame;

  /// Full-resolution coding-group identifier within [frame].
  final int groupId;

  /// Low-frequency group containing this coding group.
  final LowFrequencyGroup lowFrequencyGroup;

  /// Entropy preset selected for this coding group.
  late final int highFrequencyPreset;

  /// Entropy stream carrying this group's coefficient tokens.
  late final EntropyStream stream;

  /// Per channel: flat (coefficientHeight x coefficientWidth) arrays.
  late final List<Float32List> quantizedCoefficients;

  /// Dequantized coefficients for the first color channel.
  late final List<Float32List> dequantizedHighFrequencyCoefficients0;

  /// Dequantized coefficients for the second color channel.
  late final List<Float32List> dequantizedHighFrequencyCoefficients1;

  /// Dequantized coefficients for the third color channel.
  late final List<Float32List> dequantizedHighFrequencyCoefficients2;

  /// Coefficient-plane height for each color channel.
  late final List<int> coefficientHeight;

  /// Whether the high-frequency coefficient group has SIMD views.
  late final bool hasSimdViews;

  /// Four-lane view of [dequantizedHighFrequencyCoefficients0].
  late final List<Float32x4List> dequantizedHighFrequencyCoefficientsSimd0;

  /// Four-lane view of [dequantizedHighFrequencyCoefficients1].
  late final List<Float32x4List> dequantizedHighFrequencyCoefficientsSimd1;

  /// Four-lane view of [dequantizedHighFrequencyCoefficients2].
  late final List<Float32x4List> dequantizedHighFrequencyCoefficientsSimd2;

  /// Four-lane views of the quantized coefficient planes.
  late final List<Float32x4List> quantizedCoefficientsSimd;

  /// Coefficient-plane width for each color channel.
  late final List<int> coefficientWidth;

  /// Vertical block origin within [lowFrequencyGroup].
  late final int groupOriginY;

  /// Horizontal block origin within [lowFrequencyGroup].
  late final int groupOriginX;

  /// lowFrequencyGroup block indices belonging to this group (see
  /// `HighFrequencyMetadata.blockIndicesByGroup`).
  late final Int32List includedIndices;

  /// Decodes one pass group's entropy-coded VarDCT coefficients.
  HighFrequencyCoefficients({
    required BitReader reader,
    required this.frame,
    required int pass,
    required this.groupId,
  }) : lowFrequencyGroup = frame.lowFrequencyGroupFor(groupId) {
    final HighFrequencyGlobal highFrequencyGlobal = frame.highFrequencyGlobal!;
    final int bits = ceilLog1p(highFrequencyGlobal.highFrequencyPresetCount - 1);
    highFrequencyPreset = reader.readBits(bits);
    final HighFrequencyBlockContext highFrequencyBlockContext = frame.lowFrequencyGlobal.highFrequencyBlockContext!;
    final int offset = 495 * highFrequencyBlockContext.clusterCount * highFrequencyPreset;
    final FrameHeader header = frame.header;
    final int coefficientShift = header.passes.coefficientShifts[pass];
    final HighFrequencyPass highFrequencyPass = frame.passes[pass].highFrequencyPass!;
    final ({int height, int width}) size = frame.groupSize(groupId);
    final nonZeroes = Int32List(3 * 32 * 32);
    stream = EntropyStream.clone(other: highFrequencyPass.contextStream);
    quantizedCoefficients = [];
    coefficientHeight = List.filled(3, 0);
    coefficientWidth = List.filled(3, 0);
    for (var c = 0; c < 3; c++) {
      final int sY = size.height >> header.jpegVerticalUpsamplingShift[c];
      final int sX = size.width >> header.jpegHorizontalUpsamplingShift[c];
      coefficientHeight[c] = sY;
      coefficientWidth[c] = sX;
      quantizedCoefficients.add(Float32List(sY * sX));
    }
    dequantizedHighFrequencyCoefficients0 = floatMatrix(coefficientHeight[0], coefficientWidth[0]);
    dequantizedHighFrequencyCoefficients1 = floatMatrix(coefficientHeight[1], coefficientWidth[1]);
    dequantizedHighFrequencyCoefficients2 = floatMatrix(coefficientHeight[2], coefficientWidth[2]);
    hasSimdViews = coefficientWidth[0] & 3 == 0 && coefficientWidth[1] & 3 == 0 && coefficientWidth[2] & 3 == 0;
    if (hasSimdViews) {
      dequantizedHighFrequencyCoefficientsSimd0 = rowVectorViews(dequantizedHighFrequencyCoefficients0);
      dequantizedHighFrequencyCoefficientsSimd1 = rowVectorViews(dequantizedHighFrequencyCoefficients1);
      dequantizedHighFrequencyCoefficientsSimd2 = rowVectorViews(dequantizedHighFrequencyCoefficients2);
      quantizedCoefficientsSimd = [for (final qc in quantizedCoefficients) Float32x4List.view(qc.buffer, 0, qc.length >> 2)];
    }
    final ({int x, int y}) pos = frame.groupPositionInLowFrequencyGroup(lowFrequencyGroup.lowFrequencyGroupId, groupId);
    groupOriginY = pos.y << 5;
    groupOriginX = pos.x << 5;

    final HighFrequencyMetadata meta = lowFrequencyGroup.highFrequencyMetadata!;
    // Every block in this bucket is, by construction, within this group's
    // 32x32 block grid (see blockIndicesByGroup) — no per-block range check
    // needed, unlike a full scan-and-skip over every block in the LF group.
    includedIndices = meta.blockIndicesByGroup()[pos.y * 8 + pos.x];
    for (final int i in includedIndices) {
      final int posY = meta.blockRows[i];
      final int posX = meta.blockColumns[i];
      final int groupY = posY - groupOriginY;
      final int groupX = posX - groupOriginX;
      final TransformType tt = meta.transformTypeAt(posY, posX)!;
      final bool flip = tt.flip;
      final int highFrequencyMultiplier = meta.highFrequencyMultiplierAt(posY, posX);
      final int lowFrequencyIndex = lowFrequencyGroup.lowFrequencyCoefficients!.lowFrequencyIndex[posY * meta.blockWidth + posX];
      final int blockCount = tt.dctSelectHeight * tt.dctSelectWidth;
      for (final int c in colorChannelOrder) {
        final int sGroupY = groupY >> header.jpegVerticalUpsamplingShift[c];
        final int sGroupX = groupX >> header.jpegHorizontalUpsamplingShift[c];
        if (groupY != sGroupY << header.jpegVerticalUpsamplingShift[c] || groupX != sGroupX << header.jpegHorizontalUpsamplingShift[c]) {
          continue; // subsampled block
        }
        final int pixelGroupY = sGroupY << 3;
        final int pixelGroupX = sGroupX << 3;
        // A block must fit within its 32x32 group grid; a corrupt oversized
        // transform near the edge would otherwise index past nonZeroes.
        if (sGroupY + tt.dctSelectHeight > 32 || sGroupX + tt.dctSelectWidth > 32) {
          throw const JpegXlInvalidBitstreamException(message: 'transform block extends past its group');
        }
        final int predicted = getPredictedNonZeroes(nonZeroes, c, sGroupY, sGroupX);
        final int blockCtx = blockContextFor(highFrequencyBlockContext, c, tt.orderIdentifier, highFrequencyMultiplier, lowFrequencyIndex);
        final int nonZeroCtx = offset + nonZeroContextFor(highFrequencyBlockContext, predicted, blockCtx);
        int nonZero = stream.readSymbol(reader, nonZeroCtx);
        if (nonZero > tt.pixelHeight * tt.pixelWidth - blockCount) {
          throw const JpegXlInvalidBitstreamException(message: 'nonzero coefficient count out of range');
        }
        final int base = c * 1024;
        final int fill = blockCount == 1 ? nonZero : (nonZero + blockCount - 1) ~/ blockCount;
        for (var iy = 0; iy < tt.dctSelectHeight; iy++) {
          for (var ix = 0; ix < tt.dctSelectWidth; ix++) {
            nonZeroes[base + (sGroupY + iy) * 32 + sGroupX + ix] = fill;
          }
        }
        // SPEC: the spec doesn't say to abort here if nonZero == 0.
        if (nonZero <= 0) {
          continue;
        }
        final int orderSize = highFrequencyPass.orderFor(tt.orderIdentifier)[c].length;
        final int ucoeffLen = orderSize - blockCount;
        final int histCtx = offset + 458 * blockCtx + 37 * highFrequencyBlockContext.clusterCount;
        var prevCoeff = 0;
        final Int32List orderList = highFrequencyPass.orderFor(tt.orderIdentifier)[c];
        final Float32List qc = quantizedCoefficients[c];
        final int qw = coefficientWidth[c];
        for (var k = 0; k < ucoeffLen; k++) {
          // SPEC: the spec has this condition flipped.
          final prev = k == 0 ? (nonZero > orderSize ~/ 16 ? 0 : 1) : (prevCoeff != 0 ? 1 : 0);
          final int ctx = histCtx + coefficientContextFor(k + blockCount, nonZero, blockCount, prev);
          final int u = stream.readSymbol(reader, ctx);
          prevCoeff = u;
          final int order = orderList[k + blockCount];
          final int oy = order >> 16;
          final int ox = order & 0xFFFF;
          final int posY2 = (flip ? ox : oy) + pixelGroupY;
          final int posX2 = (flip ? oy : ox) + pixelGroupX;
          qc[posY2 * qw + posX2] = (unpackSigned(u) << coefficientShift).toDouble();
          if (u != 0) {
            if (--nonZero == 0) {
              break;
            }
          }
        }
        // SPEC: the spec doesn't mention that nonZero > 0 is illegal.
        if (nonZero != 0) {
          throw JpegXlInvalidBitstreamException(message: 'illegal final nonzero count in group $groupId');
        }
      }
    }
    if (!stream.validateFinalState()) {
      throw JpegXlInvalidBitstreamException(message: 'illegal final ANS state in pass group: $pass, $groupId');
    }

    // JPEG reconstruction: capture the raster-frequency AC of each block. JPEG
    // component `colorChannelOrder[c]` is `quantizedCoefficients[c]`. Re-derives the per-channel
    // block placement (mirrors the decode loop) so the nonzero-count skip and
    // subsampled-block skip do not interfere with capture.
    final JpegCoefficientSink? sink = frame.jpegCoefficientSink;
    if (sink != null) {
      final ({int x, int y}) lowFrequencyLocation = frame.lowFrequencyGroupLocation(lowFrequencyGroup.lowFrequencyGroupId);
      final int lowFrequencyBlockStride = header.lowFrequencyGroupDimension >> 3;
      for (final int i in includedIndices) {
        final int posY = meta.blockRows[i];
        final int posX = meta.blockColumns[i];
        final TransformType? tt = meta.transformTypeAt(posY, posX);
        if (tt == null || tt.dctSelectHeight != 1 || tt.dctSelectWidth != 1) {
          sink.containsNonDct8 = true; // JPEG has only 8x8 blocks.
        }
        for (final int c in colorChannelOrder) {
          final int upY = header.jpegVerticalUpsamplingShift[c];
          final int upX = header.jpegHorizontalUpsamplingShift[c];
          final int groupY = posY - groupOriginY;
          final int groupX = posX - groupOriginX;
          final int sGroupY = groupY >> upY;
          final int sGroupX = groupX >> upX;
          if (groupY != sGroupY << upY || groupX != sGroupX << upX) {
            continue;
          }
          final int globalBlockY = ((lowFrequencyLocation.y * lowFrequencyBlockStride) >> upY) + (posY >> upY);
          final int globalBlockX = ((lowFrequencyLocation.x * lowFrequencyBlockStride) >> upX) + (posX >> upX);
          sink.setAcCoefficients(colorChannelOrder[c], globalBlockY, globalBlockX, quantizedCoefficients[c], sGroupY << 3, sGroupX << 3, coefficientWidth[c]);
          // Chroma (X->Cb via xFromY, B->Cr via bFromY): record the block's
          // 64x64 color-tile CfL factor for later integer-exact inversion.
          if (c == 0 || c == 2) {
            final ModularChannel corr = meta.highFrequencyStreamChannels[c == 0 ? 0 : 1];
            final int corrW = corr.width;
            sink.setChromaFromLumaFactor(colorChannelOrder[c], globalBlockY, globalBlockX, corr.buffer![(posY >> 3) * corrW + (posX >> 3)]);
          }
        }
      }
    }
  }

  /// Returns the dequantized coefficient plane for [colorChannel].
  List<Float32List> dequantizedHighFrequencyCoefficientsAt(int colorChannel) => colorChannel == 0
      ? dequantizedHighFrequencyCoefficients0
      : colorChannel == 1
      ? dequantizedHighFrequencyCoefficients1
      : dequantizedHighFrequencyCoefficients2;

  /// Returns the four-lane dequantized coefficient plane for [colorChannel].
  List<Float32x4List> dequantizedHighFrequencyCoefficientsSimdAt(int colorChannel) => colorChannel == 0
      ? dequantizedHighFrequencyCoefficientsSimd0
      : colorChannel == 1
      ? dequantizedHighFrequencyCoefficientsSimd1
      : dequantizedHighFrequencyCoefficientsSimd2;

  /// Builds dequantized coefficients.
  void bakeDequantizedCoefficients() {
    _dequantizeHighFrequencyCoefficients();
    _chromaFromLuma();
    _finalizeLowestFrequencyCoefficients();
  }

  /// Public so the lossy encoder can compute the exact same block-context
  /// cluster id the decoder does, without hand-duplicating the formula.
  static int blockContextFor(HighFrequencyBlockContext highFrequencyBlockContext, int c, int orderIdentifier, int highFrequencyMultiplier, int lowFrequencyIndex) {
    int idx = (c < 2 ? 1 - c : c) * 13 + orderIdentifier;
    idx *= highFrequencyBlockContext.quantizationFieldThresholds.length + 1;
    for (final int threshold in highFrequencyBlockContext.quantizationFieldThresholds) {
      if (highFrequencyMultiplier > threshold) {
        idx++;
      }
    }
    idx *= highFrequencyBlockContext.lowFrequencyContextCount;
    return highFrequencyBlockContext.clusterMap[idx + lowFrequencyIndex];
  }

  /// Public so the lossy encoder can compute the exact same non-zero-count
  /// context id the decoder does.
  static int nonZeroContextFor(HighFrequencyBlockContext highFrequencyBlockContext, int predictedCount, int ctx) {
    int predicted = predictedCount;
    if (predicted > 64) {
      predicted = 64;
    }
    if (predicted < 8) {
      return ctx + highFrequencyBlockContext.clusterCount * predicted;
    }
    return ctx + highFrequencyBlockContext.clusterCount * (4 + predicted ~/ 2);
  }

  /// Public so the lossy encoder can compute the exact same per-position
  /// coefficient context id the decoder does (mirrors `_coeffNumNonzeroCtx`
  /// / `_coeffFreqCtx` exactly, without hand-duplicating those tables).
  static int coefficientContextFor(int coefficientIndex, int nonZeroCount, int blockCount, int prev) {
    int k = coefficientIndex;
    int nonZeroes = nonZeroCount;
    // blockCount == 1 (a single 8x8-or-smaller transform, the overwhelming
    // common case) makes both divisions identities; skip them.
    if (blockCount != 1) {
      nonZeroes = (nonZeroes + blockCount - 1) ~/ blockCount;
      k ~/= blockCount;
    }
    return (_coeffNumNonzeroCtx[nonZeroes] + _coeffFreqCtx[k]) * 2 + prev;
  }

  /// Public so the lossy encoder can maintain the exact same
  /// predicted-non-zero-count grid the decoder does.
  static int getPredictedNonZeroes(Int32List nonZeroes, int c, int y, int x) {
    final int base = c * 1024;
    if (x == 0 && y == 0) {
      return 32;
    }
    if (x == 0) {
      return nonZeroes[base + (y - 1) * 32];
    }
    if (y == 0) {
      return nonZeroes[base + x - 1];
    }
    return (nonZeroes[base + (y - 1) * 32 + x] + nonZeroes[base + y * 32 + x - 1] + 1) >> 1;
  }

  /// Dequantizes high-frequency coefficients.
  void _dequantizeHighFrequencyCoefficients() {
    final OpsinInverseMatrix matrix = frame.globalMetadata.opsinInverseMatrix;
    final FrameHeader header = frame.header;
    final double globalScale = 65536.0 / frame.lowFrequencyGlobal.globalScale;
    final scaleFactor = <double>[globalScale * math.pow(0.8, header.xQuantizationScale - 2.0).toDouble(), globalScale, globalScale * math.pow(0.8, header.bQuantizationScale - 2.0).toDouble()];
    final HighFrequencyGlobal highFrequencyGlobal = frame.highFrequencyGlobal!;
    final List<int> weightWidths = highFrequencyGlobal.weightWidths;
    final vnum = Float32x4.splat(matrix.quantBiasNumerator);
    final vone = Float32x4.splat(1.0);
    final vzero = Float32x4.zero();
    final vbias = [Float32x4.splat(matrix.quantBias[0]), Float32x4.splat(matrix.quantBias[1]), Float32x4.splat(matrix.quantBias[2])];
    final List<List<double>> qbclut = [
      [-matrix.quantBias[0], 0.0, matrix.quantBias[0]],
      [-matrix.quantBias[1], 0.0, matrix.quantBias[1]],
      [-matrix.quantBias[2], 0.0, matrix.quantBias[2]],
    ];
    final HighFrequencyMetadata meta = lowFrequencyGroup.highFrequencyMetadata!;
    for (final int i in includedIndices) {
      final int posY = meta.blockRows[i];
      final int posX = meta.blockColumns[i];
      final TransformType tt = meta.transformTypeAt(posY, posX)!;
      final int groupY = posY - groupOriginY;
      final int groupX = posX - groupOriginX;
      final bool flip = tt.flip;
      final List<Float32List?> w2 = highFrequencyGlobal.flattenedWeightsFor(tt.parameterIndex);
      final int w3w = weightWidths[tt.parameterIndex];
      for (var c = 0; c < 3; c++) {
        final int sGroupY = groupY >> header.jpegVerticalUpsamplingShift[c];
        final int sGroupX = groupX >> header.jpegHorizontalUpsamplingShift[c];
        if (groupY != sGroupY << header.jpegVerticalUpsamplingShift[c] || groupX != sGroupX << header.jpegHorizontalUpsamplingShift[c]) {
          continue; // subsampled block
        }
        final double sfc = scaleFactor[c] / meta.highFrequencyMultiplierAt(posY, posX);
        final int pixelGroupY = sGroupY << 3;
        final int pixelGroupX = sGroupX << 3;
        final int qw = coefficientWidth[c];
        if (hasSimdViews && tt.pixelWidth & 3 == 0) {
          // Vector path: LLF positions hold zero coefficients and produce
          // zero here (finalizeLLF overwrites them), so no skip test is
          // needed. quant for |coeff| < 2 is exactly bias * coeff, and
          // flipped transforms read the pre-transposed weights so the
          // access is always row-major with stride pixelWidth.
          final Float32x4List qcV = quantizedCoefficientsSimd[c];
          final List<Float32x4List> dqV = dequantizedHighFrequencyCoefficientsSimdAt(c);
          final Float32x4List wV = flip ? highFrequencyGlobal.transposedVectorWeights[tt.parameterIndex][c]! : highFrequencyGlobal.vectorWeights[tt.parameterIndex][c]!;
          final vsfc = Float32x4.splat(sfc);
          final Float32x4 vbiasC = vbias[c];
          final int qw4 = qw >> 2;
          final int w3w4 = tt.pixelWidth >> 2;
          final int gx4 = pixelGroupX >> 2;
          final int vecs = tt.pixelWidth >> 2;
          for (var y = 0; y < tt.pixelHeight; y++) {
            final int qRow = (pixelGroupY + y) * qw4 + gx4;
            final Float32x4List dRow = dqV[pixelGroupY + y];
            final int wRow = y * w3w4;
            for (var i = 0; i < vecs; i++) {
              final Float32x4 coeff = qcV[qRow + i];
              // Coefficients are exact integers: m is 0 for |c| < 2 and
              // 1 otherwise, all in float math (Int32x4 masks box in AOT).
              final Float32x4 m = (coeff.abs() - vone).clamp(vzero, vone);
              final Float32x4 invM = vone - m;
              final Float32x4 big = coeff - vnum / (coeff * m + invM);
              final Float32x4 quant = vbiasC * coeff * invM + big * m;
              dRow[gx4 + i] = quant * vsfc * wV[wRow + i];
            }
          }
          continue;
        }
        final Float32List w3 = w2[c]!;
        final List<double> qbc = qbclut[c];
        final Float32List qc = quantizedCoefficients[c];
        final List<Float32List> dq = dequantizedHighFrequencyCoefficientsAt(c);
        for (var y = 0; y < tt.pixelHeight; y++) {
          for (var x = 0; x < tt.pixelWidth; x++) {
            if (y < tt.dctSelectHeight && x < tt.dctSelectWidth) {
              continue;
            }
            final int pY = pixelGroupY + y;
            final int pX = pixelGroupX + x;
            final double coeff = qc[pY * qw + pX];
            final double quant = coeff > -2 && coeff < 2 ? qbc[coeff.toInt() + 1] : coeff - matrix.quantBiasNumerator / coeff;
            final wy = flip ? x : y;
            final int wx = x ^ y ^ wy;
            dq[pY][pX] = quant * sfc * w3[wy * w3w + wx];
          }
        }
      }
    }
  }

  /// Restores the opsin X and B coefficients predicted from luma.
  void _chromaFromLuma() {
    if (frame.header.isSubsampled) {
      return;
    }
    final LowFrequencyChannelCorrelation correlation = frame.lowFrequencyGlobal.lowFrequencyChannelCorrelation;
    final HighFrequencyMetadata metadata = lowFrequencyGroup.highFrequencyMetadata!;
    final ModularChannel xFromY = metadata.highFrequencyStreamChannels[0];
    final ModularChannel bFromY = metadata.highFrequencyStreamChannels[1];
    final int correlationWidth = xFromY.width;
    final Int32List highFrequencyXFactors = xFromY.buffer!;
    final Int32List highFrequencyBFactors = bFromY.buffer!;
    final List<Float32List> xFactors = floatMatrix(xFromY.height, correlationWidth);
    final List<Float32List> bFactors = floatMatrix(bFromY.height, correlationWidth);
    final List<Float32List> dequantizedX = dequantizedHighFrequencyCoefficients0;
    final List<Float32List> dequantizedY = dequantizedHighFrequencyCoefficients1;
    final List<Float32List> dequantizedB = dequantizedHighFrequencyCoefficients2;
    for (final int i in includedIndices) {
      final int blockY = metadata.blockRows[i];
      final int blockX = metadata.blockColumns[i];
      final TransformType transformType = metadata.transformTypeAt(blockY, blockX)!;
      final int pixelOriginY = blockY << 3;
      final int pixelOriginX = blockX << 3;
      for (var iy = 0; iy < transformType.pixelHeight; iy++) {
        final int y = pixelOriginY + iy;
        final int fy = y >> 6;
        final bool isFirstRowInCorrelationRegion = fy << 6 == y;
        final Float32List cachedXFactors = xFactors[fy];
        final Float32List cachedBFactors = bFactors[fy];
        for (var ix = 0; ix < transformType.pixelWidth; ix++) {
          final int x = pixelOriginX + ix;
          final int fx = x >> 6;
          double xCorrelation;
          double bCorrelation;
          if (isFirstRowInCorrelationRegion && fx << 6 == x) {
            xCorrelation = correlation.baseCorrelationX + highFrequencyXFactors[fy * correlationWidth + fx] / correlation.colorFactor;
            bCorrelation = correlation.baseCorrelationB + highFrequencyBFactors[fy * correlationWidth + fx] / correlation.colorFactor;
            cachedXFactors[fx] = xCorrelation;
            cachedBFactors[fx] = bCorrelation;
          } else {
            xCorrelation = cachedXFactors[fx];
            bCorrelation = cachedBFactors[fx];
          }
          final double dequantizedLuma = dequantizedY[y & 0xFF][x & 0xFF];
          dequantizedX[y & 0xFF][x & 0xFF] += xCorrelation * dequantizedLuma;
          dequantizedB[y & 0xFF][x & 0xFF] += bCorrelation * dequantizedLuma;
        }
      }
    }
  }

  /// Finalizes lowest-frequency.
  void _finalizeLowestFrequencyCoefficients() {
    final List<Float32List> scratch0 = floatMatrix(32, 32);
    final List<Float32List> scratch1 = floatMatrix(32, 32);
    final FrameHeader header = frame.header;
    final HighFrequencyMetadata meta = lowFrequencyGroup.highFrequencyMetadata!;
    for (final int i in includedIndices) {
      final int posY = meta.blockRows[i];
      final int posX = meta.blockColumns[i];
      final TransformType tt = meta.transformTypeAt(posY, posX)!;
      final int groupY = posY - groupOriginY;
      final int groupX = posX - groupOriginX;
      for (var c = 0; c < 3; c++) {
        final int sGroupY = groupY >> header.jpegVerticalUpsamplingShift[c];
        final int sGroupX = groupX >> header.jpegHorizontalUpsamplingShift[c];
        if (groupY != sGroupY << header.jpegVerticalUpsamplingShift[c] || groupX != sGroupX << header.jpegHorizontalUpsamplingShift[c]) {
          continue; // subsampled block
        }
        final int pixelGroupY = sGroupY << 3;
        final int pixelGroupX = sGroupX << 3;
        final int sLfgY = posY >> header.jpegVerticalUpsamplingShift[c];
        final int sLfgX = posX >> header.jpegHorizontalUpsamplingShift[c];
        final List<Float32List> dqlf = lowFrequencyGroup.lowFrequencyCoefficients!.dequantizedLowFrequencyCoefficientsAt(c);
        final List<Float32List> dq = dequantizedHighFrequencyCoefficientsAt(c);
        forwardDct2d(dqlf, dq, sLfgY, sLfgX, pixelGroupY, pixelGroupX, tt.dctSelectHeight, tt.dctSelectWidth, scratch0, scratch1);
        for (var y = 0; y < tt.dctSelectHeight; y++) {
          final Float32List dqy = dq[y + pixelGroupY];
          for (var x = 0; x < tt.dctSelectWidth; x++) {
            dqy[x + pixelGroupX] *= tt.lowestFrequencyScale[y * tt.dctSelectWidth + x];
          }
        }
      }
    }
  }
}
