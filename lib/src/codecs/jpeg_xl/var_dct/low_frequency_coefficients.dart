import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/low_frequency_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_coefficient_sink.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_block_context.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/low_frequency_channel_correlation.dart';

/// Holds dequantized DC coefficients and context indices for one low-frequency group.
final class LowFrequencyCoefficients {
  /// Dequantized coefficients for the first color channel.
  late final List<Float32List> dequantizedLowFrequencyCoefficients0;

  /// Dequantized coefficients for the second color channel.
  late final List<Float32List> dequantizedLowFrequencyCoefficients1;

  /// Dequantized coefficients for the third color channel.
  late final List<Float32List> dequantizedLowFrequencyCoefficients2;

  /// Context index assigned to each low-frequency block.
  late final Int32List lowFrequencyIndex;

  /// Decodes the low-frequency coefficients owned by [parent].
  LowFrequencyCoefficients({
    required BitReader reader,
    required LowFrequencyGroup parent,
    required Frame frame,
  }) {
    final FrameHeader header = frame.header;
    lowFrequencyIndex = Int32List(parent.blockHeight * parent.blockWidth);
    final adaptiveSmoothing = header.flags & (FrameFlags.skipAdaptiveLfSmoothing | FrameFlags.useLfFrame) == 0;
    final bool subsampled = header.isSubsampled;
    if (adaptiveSmoothing && subsampled) {
      throw const JpegXlInvalidBitstreamException(message: 'adaptive smoothing is incompatible with subsampling');
    }

    final info = List<ModularChannel?>.filled(3, null);
    var coeff = <List<Float32List>>[];
    for (var i = 0; i < 3; i++) {
      final int sizeY = parent.blockHeight >> header.jpegVerticalUpsamplingShift[i];
      final int sizeX = parent.blockWidth >> header.jpegHorizontalUpsamplingShift[i];
      info[colorChannelOrder[i]] = ModularChannel(height: sizeY, width: sizeX, verticalShift: header.jpegVerticalUpsamplingShift[i], horizontalShift: header.jpegHorizontalUpsamplingShift[i]);
      coeff.add(floatMatrix(sizeY, sizeX));
    }

    if (header.flags & FrameFlags.useLfFrame != 0) {
      // The dequantized LF is a direct copy of the LF frame's pixels at
      // this LF group's position; the LF context indices stay zero.
      final List<ImageBuffer> lowFrequencyFrame = frame.lowFrequencyFrame!;
      final ({int x, int y}) pos = frame.lowFrequencyGroupLocation(parent.lowFrequencyGroupId);
      final int pY = pos.y << 8;
      final int pX = pos.x << 8;
      for (var c = 0; c < 3; c++) {
        lowFrequencyFrame[c].castToFloat(frame.globalMetadata.bitDepth.bitsPerSample);
        final List<Float32List> b = lowFrequencyFrame[c].floatRows;
        final List<Float32List> co = coeff[c];
        for (var y = 0; y < co.length; y++) {
          co[y].setRange(0, co[y].length, b[pY + y], pX);
        }
      }
      dequantizedLowFrequencyCoefficients0 = List<Float32List>.of(coeff[0], growable: false);
      dequantizedLowFrequencyCoefficients1 = List<Float32List>.of(coeff[1], growable: false);
      dequantizedLowFrequencyCoefficients2 = List<Float32List>.of(coeff[2], growable: false);
      return;
    }

    final int extraPrecision = reader.readBits(2);
    final lowFrequencyQuantizationStream = ModularStream.read(reader: reader, context: frame.modularContext, streamIndex: 1 + parent.lowFrequencyGroupId, channelArray: info.cast<ModularChannel>());
    lowFrequencyQuantizationStream.decodeChannels(reader);
    // lfQuant channels are in Y, X, B order.
    final List<ModularChannel> lfQuant = [for (var i = 0; i < 3; i++) lowFrequencyQuantizationStream.getChannel(i)];

    // JPEG reconstruction: capture the pre-dequant integer DC. JPEG component
    // `ch` is `lfQuant[ch]`; its block grid follows channel `colorChannelOrder[ch]`'s
    // subsampling.
    final JpegCoefficientSink? sink = frame.jpegCoefficientSink;
    if (sink != null) {
      final ({int x, int y}) lowFrequencyLocation = frame.lowFrequencyGroupLocation(parent.lowFrequencyGroupId);
      final int lowFrequencyBlockStride = header.lowFrequencyGroupDimension >> 3;
      for (var ch = 0; ch < 3; ch++) {
        final ModularChannel chan = lfQuant[ch];
        final int offY = (lowFrequencyLocation.y * lowFrequencyBlockStride) >> header.jpegVerticalUpsamplingShift[colorChannelOrder[ch]];
        final int offX = (lowFrequencyLocation.x * lowFrequencyBlockStride) >> header.jpegHorizontalUpsamplingShift[colorChannelOrder[ch]];
        final Int32List buf = chan.buffer!;
        for (var y = 0; y < chan.height; y++) {
          final int row = y * chan.width;
          for (var x = 0; x < chan.width; x++) {
            sink.setDcCoefficient(ch, offY + y, offX + x, buf[row + x]);
          }
        }
      }
    }

    final List<double> scaledDequantization = frame.lowFrequencyGlobal.scaledDequantization;
    for (var i = 0; i < 3; i++) {
      final int c = colorChannelOrder[i];
      final double sd = scaledDequantization[i] / (1 << extraPrecision);
      final ModularChannel chan = lfQuant[c];
      final Int32List q = chan.buffer!;
      for (var y = 0; y < chan.height; y++) {
        final Float32List dq = coeff[i][y];
        for (var x = 0; x < chan.width; x++) {
          dq[x] = q[y * chan.width + x] * sd;
        }
      }
    }

    // Chroma from luma.
    if (!subsampled) {
      final LowFrequencyChannelCorrelation correlation = frame.lowFrequencyGlobal.lowFrequencyChannelCorrelation;
      // SPEC: -128, not -127.
      final double xCorrelation = correlation.baseCorrelationX + (correlation.lowFrequencyXFactor - 128.0) / correlation.colorFactor;
      final double bCorrelation = correlation.baseCorrelationB + (correlation.lowFrequencyBFactor - 128.0) / correlation.colorFactor;
      final List<Float32List> dequantizedY = coeff[1];
      final List<Float32List> dequantizedX = coeff[0];
      final List<Float32List> dequantizedB = coeff[2];
      for (var y = 0; y < dequantizedY.length; y++) {
        final Float32List yRow = dequantizedY[y];
        final Float32List xRow = dequantizedX[y];
        final Float32List bRow = dequantizedB[y];
        for (var x = 0; x < yRow.length; x++) {
          xRow[x] += xCorrelation * yRow[x];
          bRow[x] += bCorrelation * yRow[x];
        }
      }
    }

    if (adaptiveSmoothing) {
      coeff = _adaptiveSmooth(coeff, scaledDequantization);
    }
    dequantizedLowFrequencyCoefficients0 = List<Float32List>.of(coeff[0], growable: false);
    dequantizedLowFrequencyCoefficients1 = List<Float32List>.of(coeff[1], growable: false);
    dequantizedLowFrequencyCoefficients2 = List<Float32List>.of(coeff[2], growable: false);

    // Populate LF context indices.
    final HighFrequencyBlockContext highFrequencyBlockContext = frame.lowFrequencyGlobal.highFrequencyBlockContext!;
    for (var y = 0; y < parent.blockHeight; y++) {
      for (var x = 0; x < parent.blockWidth; x++) {
        lowFrequencyIndex[y * parent.blockWidth + x] = _lowFrequencyIndexAt(lfQuant, highFrequencyBlockContext, header, y, x);
      }
    }
  }

  /// Returns the dequantized coefficient plane for [colorChannel].
  List<Float32List> dequantizedLowFrequencyCoefficientsAt(int colorChannel) => colorChannel == 0
      ? dequantizedLowFrequencyCoefficients0
      : colorChannel == 1
      ? dequantizedLowFrequencyCoefficients1
      : dequantizedLowFrequencyCoefficients2;

  /// Applies adaptive low-frequency smoothing to all color channels.
  static List<List<Float32List>> _adaptiveSmooth(List<List<Float32List>> coeff, List<double> scaledDequantization) {
    final weighted = List<List<Float32List?>>.generate(3, (i) => List<Float32List?>.filled(coeff[i].length, null));
    final gap = List<Float32List?>.filled(coeff[0].length, null);
    for (var i = 0; i < 3; i++) {
      final List<Float32List> co = coeff[i];
      final double sd = scaledDequantization[i];
      for (var y = 1; y < co.length - 1; y++) {
        final Float32List coy = co[y];
        final Float32List coym = co[y - 1];
        final Float32List coyp = co[y + 1];
        final Float32List gy = gap[y] ??= Float32List(coy.length)..fillRange(0, coy.length, 0.5);
        final Float32List wy = weighted[i][y] = Float32List(coy.length);
        for (var x = 1; x < coy.length - 1; x++) {
          final double sample = coy[x];
          final double adjacent = coy[x - 1] + coy[x + 1] + coym[x] + coyp[x];
          final double diag = coym[x - 1] + coym[x + 1] + coyp[x - 1] + coyp[x + 1];
          wy[x] = 0.05226273532324128 * sample + 0.20345139757231578 * adjacent + 0.0334829185968739 * diag;
          final double g = (sample - wy[x]).abs() * sd;
          if (g > gy[x]) {
            gy[x] = g;
          }
        }
      }
    }
    for (var y = 0; y < gap.length; y++) {
      final Float32List? gy = gap[y];
      if (gy == null) {
        continue;
      }
      for (var x = 0; x < gy.length; x++) {
        final double v = 3.0 - 4.0 * gy[x];
        gy[x] = v < 0 ? 0 : v;
      }
    }
    final out = <List<Float32List>>[];
    for (var i = 0; i < 3; i++) {
      final List<Float32List> co = coeff[i];
      final dqi = List<Float32List>.generate(co.length, (y) => Float32List(co[y].length), growable: false);
      for (var y = 0; y < co.length; y++) {
        final Float32List coy = co[y];
        final Float32List dqy = dqi[y];
        if (y == 0 || y + 1 == co.length) {
          dqy.setAll(0, coy);
          continue;
        }
        final Float32List gy = gap[y]!;
        final Float32List wiy = weighted[i][y]!;
        for (var x = 0; x < coy.length; x++) {
          if (x == 0 || x + 1 == coy.length) {
            dqy[x] = coy[x];
            continue;
          }
          dqy[x] = (coy[x] - wiy[x]) * gy[x] + wiy[x];
        }
      }
      out.add(dqi);
    }
    return out;
  }

  /// Computes the low-frequency entropy context at one block position.
  static int _lowFrequencyIndexAt(List<ModularChannel> lfQuant, HighFrequencyBlockContext highFrequencyBlockContext, FrameHeader header, int y, int x) {
    final index = List<int>.filled(3, 0);
    for (var i = 0; i < 3; i++) {
      final int sy = y >> header.jpegVerticalUpsamplingShift[i];
      final int sx = x >> header.jpegHorizontalUpsamplingShift[i];
      final Int32List thresholds = highFrequencyBlockContext.lowFrequencyThresholds[i];
      final ModularChannel chan = lfQuant[colorChannelOrder[i]];
      final int v = chan.buffer![sy * chan.width + sx];
      for (var j = 0; j < thresholds.length; j++) {
        if (v > thresholds[j]) {
          index[i]++;
        }
      }
    }
    int lowFrequencyIndex = index[0];
    lowFrequencyIndex *= highFrequencyBlockContext.lowFrequencyThresholds[2].length + 1;
    lowFrequencyIndex += index[2];
    lowFrequencyIndex *= highFrequencyBlockContext.lowFrequencyThresholds[1].length + 1;
    lowFrequencyIndex += index[1];
    return lowFrequencyIndex;
  }
}
