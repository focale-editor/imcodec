import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/lf_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg/jpeg_coeff_sink.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_block_context.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/lf_channel_correlation.dart';

/// Dequantized LF (DC) coefficients of one LF group, plus the per-block
/// LF context indices.
final class LfCoefficients {
  /// Stores the dequant lFCoeff0 value used while processing JPEG XL data.
  ///
  late final List<Float32List> dequantLFCoeff0;

  /// Stores the dequant lFCoeff1 value used while processing JPEG XL data.
  ///
  late final List<Float32List> dequantLFCoeff1;

  /// Stores the dequant lFCoeff2 value used while processing JPEG XL data.
  ///
  late final List<Float32List> dequantLFCoeff2;

  /// Stores the lf index value used while processing JPEG XL data.
  ///
  late final Int32List lfIndex;

  /// Creates Lf coefficients data for JPEG XL processing.
  ///
  LfCoefficients({
    required BitReader reader,
    required LfGroup parent,
    required Frame frame,
  }) {
    final FrameHeader header = frame.header;
    lfIndex = Int32List(parent.blockHeight * parent.blockWidth);
    final adaptiveSmoothing = header.flags & (FrameFlags.skipAdaptiveLfSmoothing | FrameFlags.useLfFrame) == 0;
    final bool subsampled = header.isSubsampled;
    if (adaptiveSmoothing && subsampled) {
      throw const JpegXlInvalidBitstreamException(message: 'adaptive smoothing is incompatible with subsampling');
    }

    final info = List<ModularChannel?>.filled(3, null);
    var coeff = <List<Float32List>>[];
    for (var i = 0; i < 3; i++) {
      final int sizeY = parent.blockHeight >> header.jpegUpsamplingY[i];
      final int sizeX = parent.blockWidth >> header.jpegUpsamplingX[i];
      info[cMap[i]] = ModularChannel(height: sizeY, width: sizeX, vshift: header.jpegUpsamplingY[i], hshift: header.jpegUpsamplingX[i]);
      coeff.add(floatMatrix(sizeY, sizeX));
    }

    if (header.flags & FrameFlags.useLfFrame != 0) {
      // The dequantized LF is a direct copy of the LF frame's pixels at
      // this LF group's position; the LF context indices stay zero.
      final List<ImageBuffer> lfFrame = frame.lfFrame!;
      final ({int x, int y}) pos = frame.getLFGroupLocation(parent.lfGroupID);
      final int pY = pos.y << 8;
      final int pX = pos.x << 8;
      for (var c = 0; c < 3; c++) {
        lfFrame[c].castToFloat(frame.globalMetadata.bitDepth.bitsPerSample);
        final List<Float32List> b = lfFrame[c].floatRows;
        final List<Float32List> co = coeff[c];
        for (var y = 0; y < co.length; y++) {
          co[y].setRange(0, co[y].length, b[pY + y], pX);
        }
      }
      dequantLFCoeff0 = List<Float32List>.of(coeff[0], growable: false);
      dequantLFCoeff1 = List<Float32List>.of(coeff[1], growable: false);
      dequantLFCoeff2 = List<Float32List>.of(coeff[2], growable: false);
      return;
    }

    final int extraPrecision = reader.readBits(2);
    final lfQuantStream = ModularStream.read(reader: reader, ctx: frame.modularContext, streamIndex: 1 + parent.lfGroupID, channelArray: info.cast<ModularChannel>());
    lfQuantStream.decodeChannels(reader);
    // lfQuant channels are in Y, X, B order.
    final List<ModularChannel> lfQuant = [for (var i = 0; i < 3; i++) lfQuantStream.getChannel(i)];

    // JPEG reconstruction: capture the pre-dequant integer DC. JPEG component
    // `ch` is `lfQuant[ch]`; its block grid follows channel `cMap[ch]`'s
    // subsampling.
    final JpegCoeffSink? sink = frame.jpegSink;
    if (sink != null) {
      final ({int x, int y}) lfLoc = frame.getLFGroupLocation(parent.lfGroupID);
      final int lfBlkStride = header.lfGroupDim >> 3;
      for (var ch = 0; ch < 3; ch++) {
        final ModularChannel chan = lfQuant[ch];
        final int offY = (lfLoc.y * lfBlkStride) >> header.jpegUpsamplingY[cMap[ch]];
        final int offX = (lfLoc.x * lfBlkStride) >> header.jpegUpsamplingX[cMap[ch]];
        final Int32List buf = chan.buffer!;
        for (var y = 0; y < chan.height; y++) {
          final int row = y * chan.width;
          for (var x = 0; x < chan.width; x++) {
            sink.setDc(ch, offY + y, offX + x, buf[row + x]);
          }
        }
      }
    }

    final List<double> scaledDequant = frame.lfGlobal.scaledDequant;
    for (var i = 0; i < 3; i++) {
      final int c = cMap[i];
      final double sd = scaledDequant[i] / (1 << extraPrecision);
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
      final LfChannelCorrelation lfc = frame.lfGlobal.lfChanCorr;
      // SPEC: -128, not -127.
      final double kX = lfc.baseCorrelationX + (lfc.xFactorLF - 128.0) / lfc.colorFactor;
      final double kB = lfc.baseCorrelationB + (lfc.bFactorLF - 128.0) / lfc.colorFactor;
      final List<Float32List> dqLFY = coeff[1];
      final List<Float32List> dqLFX = coeff[0];
      final List<Float32List> dqLFB = coeff[2];
      for (var y = 0; y < dqLFY.length; y++) {
        final Float32List yRow = dqLFY[y];
        final Float32List xRow = dqLFX[y];
        final Float32List bRow = dqLFB[y];
        for (var x = 0; x < yRow.length; x++) {
          xRow[x] += kX * yRow[x];
          bRow[x] += kB * yRow[x];
        }
      }
    }

    if (adaptiveSmoothing) {
      coeff = _adaptiveSmooth(coeff, scaledDequant);
    }
    dequantLFCoeff0 = List<Float32List>.of(coeff[0], growable: false);
    dequantLFCoeff1 = List<Float32List>.of(coeff[1], growable: false);
    dequantLFCoeff2 = List<Float32List>.of(coeff[2], growable: false);

    // Populate LF context indices.
    final HfBlockContext hfctx = frame.lfGlobal.hfBlockCtx!;
    for (var y = 0; y < parent.blockHeight; y++) {
      for (var x = 0; x < parent.blockWidth; x++) {
        lfIndex[y * parent.blockWidth + x] = _getLFIndex(lfQuant, hfctx, header, y, x);
      }
    }
  }

  /// Processes dequant lFCoeff at information in a JPEG XL codestream.
  ///
  List<Float32List> dequantLFCoeffAt(int c) => c == 0 ? dequantLFCoeff0 : (c == 1 ? dequantLFCoeff1 : dequantLFCoeff2);

  /// Processes the adaptive smooth data used by the JPEG XL codec.
  ///
  static List<List<Float32List>> _adaptiveSmooth(List<List<Float32List>> coeff, List<double> scaledDequant) {
    final weighted = List<List<Float32List?>>.generate(3, (i) => List<Float32List?>.filled(coeff[i].length, null));
    final gap = List<Float32List?>.filled(coeff[0].length, null);
    for (var i = 0; i < 3; i++) {
      final List<Float32List> co = coeff[i];
      final double sd = scaledDequant[i];
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

  /// Processes the get lfindex data used by the JPEG XL codec.
  ///
  static int _getLFIndex(List<ModularChannel> lfQuant, HfBlockContext hfctx, FrameHeader header, int y, int x) {
    final index = List<int>.filled(3, 0);
    for (var i = 0; i < 3; i++) {
      final int sy = y >> header.jpegUpsamplingY[i];
      final int sx = x >> header.jpegUpsamplingX[i];
      final Int32List hft = hfctx.lfThresholds[i];
      final ModularChannel chan = lfQuant[cMap[i]];
      final int v = chan.buffer![sy * chan.width + sx];
      for (var j = 0; j < hft.length; j++) {
        if (v > hft[j]) {
          index[i]++;
        }
      }
    }
    int lfIndex = index[0];
    lfIndex *= hfctx.lfThresholds[2].length + 1;
    lfIndex += index[2];
    lfIndex *= hfctx.lfThresholds[1].length + 1;
    lfIndex += index[1];
    return lfIndex;
  }
}
