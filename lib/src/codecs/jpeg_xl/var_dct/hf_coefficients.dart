import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/opsin_inverse.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/lf_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg/jpeg_coeff_sink.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/dct.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_block_context.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_global.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_metadata.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_pass.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/lf_channel_correlation.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Stores the coeff freq ctx state used internally by the JPEG XL codec.
///
const _coeffFreqCtx = <int>[
  // Index 0 is unused.
  -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, //
  15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, //
  23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26, //
  27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
];

/// Stores the coeff num nonzero ctx state used internally by the JPEG XL codec.
///
const _coeffNumNonzeroCtx = <int>[
  // Index 0 is unused.
  -1, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123, 152, 152, //
  152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180, 180, 180, //
  180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206, 206, 206, //
  206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, //
  206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
];

/// AC coefficients of one (pass, group): entropy decode, dequantization,
/// chroma-from-luma and LLF insertion.
final class HfCoefficients {
  /// Stores the frame value used while processing JPEG XL data.
  ///
  final Frame frame;

  /// Stores the group iD value used while processing JPEG XL data.
  ///
  final int groupID;

  /// Stores the lfg value used while processing JPEG XL data.
  ///
  final LfGroup lfg;

  /// Stores the hf preset value used while processing JPEG XL data.
  ///
  late final int hfPreset;

  /// Stores the stream value used while processing JPEG XL data.
  ///
  late final EntropyStream stream;

  /// Per channel: flat (coeffHeight x coeffWidth) arrays.
  late final List<Float32List> quantizedCoeffs;

  /// Stores the dequant hFCoeff0 value used while processing JPEG XL data.
  ///
  late final List<Float32List> dequantHFCoeff0;

  /// Stores the dequant hFCoeff1 value used while processing JPEG XL data.
  ///
  late final List<Float32List> dequantHFCoeff1;

  /// Stores the dequant hFCoeff2 value used while processing JPEG XL data.
  ///
  late final List<Float32List> dequantHFCoeff2;

  /// Stores the coeff height value used while processing JPEG XL data.
  ///
  late final List<int> coeffHeight;

  /// Stores the simd views value used while processing JPEG XL data.
  ///
  late final bool simdViews;

  /// Stores the dequant hFCoeff v0 value used while processing JPEG XL data.
  ///
  late final List<Float32x4List> dequantHFCoeffV0;

  /// Stores the dequant hFCoeff v1 value used while processing JPEG XL data.
  ///
  late final List<Float32x4List> dequantHFCoeffV1;

  /// Stores the dequant hFCoeff v2 value used while processing JPEG XL data.
  ///
  late final List<Float32x4List> dequantHFCoeffV2;

  /// Stores the quantized coeffs v value used while processing JPEG XL data.
  ///
  late final List<Float32x4List> quantizedCoeffsV;

  /// Stores the coeff width value used while processing JPEG XL data.
  ///
  late final List<int> coeffWidth;

  /// Stores the group pos y value used while processing JPEG XL data.
  ///
  late final int groupPosY;

  /// Stores the group pos x value used while processing JPEG XL data.
  ///
  late final int groupPosX;

  /// lfg block indices belonging to this group (see
  /// `HfMetadata.blockIndicesByGroup`).
  late final Int32List includedIndices;

  /// Creates Hf coefficients data for JPEG XL processing.
  ///
  HfCoefficients({
    required BitReader reader,
    required this.frame,
    required int pass,
    required this.groupID,
  }) : lfg = frame.getLFGroupForGroup(groupID) {
    final HfGlobal hfGlobal = frame.hfGlobal!;
    final int bits = ceilLog1p(hfGlobal.numHfPresets - 1);
    hfPreset = reader.readBits(bits);
    final HfBlockContext hfctx = frame.lfGlobal.hfBlockCtx!;
    final int offset = 495 * hfctx.numClusters * hfPreset;
    final FrameHeader header = frame.header;
    final int shift = header.passes.shift[pass];
    final HfPass hfPass = frame.passes[pass].hfPass!;
    final ({int height, int width}) size = frame.groupSize(groupID);
    final nonZeroes = Int32List(3 * 32 * 32);
    stream = EntropyStream.clone(other: hfPass.contextStream);
    quantizedCoeffs = [];
    coeffHeight = List.filled(3, 0);
    coeffWidth = List.filled(3, 0);
    for (var c = 0; c < 3; c++) {
      final int sY = size.height >> header.jpegUpsamplingY[c];
      final int sX = size.width >> header.jpegUpsamplingX[c];
      coeffHeight[c] = sY;
      coeffWidth[c] = sX;
      quantizedCoeffs.add(Float32List(sY * sX));
    }
    dequantHFCoeff0 = floatMatrix(coeffHeight[0], coeffWidth[0]);
    dequantHFCoeff1 = floatMatrix(coeffHeight[1], coeffWidth[1]);
    dequantHFCoeff2 = floatMatrix(coeffHeight[2], coeffWidth[2]);
    simdViews = coeffWidth[0] & 3 == 0 && coeffWidth[1] & 3 == 0 && coeffWidth[2] & 3 == 0;
    if (simdViews) {
      dequantHFCoeffV0 = rowVectorViews(dequantHFCoeff0);
      dequantHFCoeffV1 = rowVectorViews(dequantHFCoeff1);
      dequantHFCoeffV2 = rowVectorViews(dequantHFCoeff2);
      quantizedCoeffsV = [for (final qc in quantizedCoeffs) Float32x4List.view(qc.buffer, 0, qc.length >> 2)];
    }
    final ({int x, int y}) pos = frame.groupPosInLFGroup(lfg.lfGroupID, groupID);
    groupPosY = pos.y << 5;
    groupPosX = pos.x << 5;

    final HfMetadata meta = lfg.hfMetadata!;
    // Every block in this bucket is, by construction, within this group's
    // 32x32 block grid (see blockIndicesByGroup) — no per-block range check
    // needed, unlike a full scan-and-skip over every block in the LF group.
    includedIndices = meta.blockIndicesByGroup()[pos.y * 8 + pos.x];
    for (final int i in includedIndices) {
      final int posY = meta.blockY[i];
      final int posX = meta.blockX[i];
      final int groupY = posY - groupPosY;
      final int groupX = posX - groupPosX;
      final TransformType tt = meta.dctSelectAt(posY, posX)!;
      final bool flip = tt.flip;
      final int hfMult = meta.hfMultiplierAt(posY, posX);
      final int lfIndex = lfg.lfCoeff!.lfIndex[posY * meta.blockWidth + posX];
      final int numBlocks = tt.dctSelectHeight * tt.dctSelectWidth;
      for (final int c in cMap) {
        final int sGroupY = groupY >> header.jpegUpsamplingY[c];
        final int sGroupX = groupX >> header.jpegUpsamplingX[c];
        if (groupY != sGroupY << header.jpegUpsamplingY[c] || groupX != sGroupX << header.jpegUpsamplingX[c]) {
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
        final int blockCtx = getBlockContext(hfctx, c, tt.orderID, hfMult, lfIndex);
        final int nonZeroCtx = offset + getNonZeroContext(hfctx, predicted, blockCtx);
        int nonZero = stream.readSymbol(reader, nonZeroCtx);
        if (nonZero > tt.pixelHeight * tt.pixelWidth - numBlocks) {
          throw const JpegXlInvalidBitstreamException(message: 'nonzero coefficient count out of range');
        }
        final int base = c * 1024;
        final int fill = numBlocks == 1 ? nonZero : (nonZero + numBlocks - 1) ~/ numBlocks;
        for (var iy = 0; iy < tt.dctSelectHeight; iy++) {
          for (var ix = 0; ix < tt.dctSelectWidth; ix++) {
            nonZeroes[base + (sGroupY + iy) * 32 + sGroupX + ix] = fill;
          }
        }
        // SPEC: the spec doesn't say to abort here if nonZero == 0.
        if (nonZero <= 0) {
          continue;
        }
        final int orderSize = hfPass.orderFor(tt.orderID)[c].length;
        final int ucoeffLen = orderSize - numBlocks;
        final int histCtx = offset + 458 * blockCtx + 37 * hfctx.numClusters;
        var prevCoeff = 0;
        final Int32List orderList = hfPass.orderFor(tt.orderID)[c];
        final Float32List qc = quantizedCoeffs[c];
        final int qw = coeffWidth[c];
        for (var k = 0; k < ucoeffLen; k++) {
          // SPEC: the spec has this condition flipped.
          final prev = k == 0 ? (nonZero > orderSize ~/ 16 ? 0 : 1) : (prevCoeff != 0 ? 1 : 0);
          final int ctx = histCtx + getCoefficientContext(k + numBlocks, nonZero, numBlocks, prev);
          final int u = stream.readSymbol(reader, ctx);
          prevCoeff = u;
          final int order = orderList[k + numBlocks];
          final int oy = order >> 16;
          final int ox = order & 0xFFFF;
          final int posY2 = (flip ? ox : oy) + pixelGroupY;
          final int posX2 = (flip ? oy : ox) + pixelGroupX;
          qc[posY2 * qw + posX2] = (unpackSigned(u) << shift).toDouble();
          if (u != 0) {
            if (--nonZero == 0) {
              break;
            }
          }
        }
        // SPEC: the spec doesn't mention that nonZero > 0 is illegal.
        if (nonZero != 0) {
          throw JpegXlInvalidBitstreamException(message: 'illegal final nonzero count in group $groupID');
        }
      }
    }
    if (!stream.validateFinalState()) {
      throw JpegXlInvalidBitstreamException(message: 'illegal final ANS state in pass group: $pass, $groupID');
    }

    // JPEG reconstruction: capture the raster-frequency AC of each block. JPEG
    // component `cMap[c]` is `quantizedCoeffs[c]`. Re-derives the per-channel
    // block placement (mirrors the decode loop) so the nonzero-count skip and
    // subsampled-block skip do not interfere with capture.
    final JpegCoeffSink? sink = frame.jpegSink;
    if (sink != null) {
      final ({int x, int y}) lfLoc = frame.getLFGroupLocation(lfg.lfGroupID);
      final int lfBlkStride = header.lfGroupDim >> 3;
      for (final int i in includedIndices) {
        final int posY = meta.blockY[i];
        final int posX = meta.blockX[i];
        final TransformType? tt = meta.dctSelectAt(posY, posX);
        if (tt == null || tt.dctSelectHeight != 1 || tt.dctSelectWidth != 1) {
          sink.nonDct8 = true; // JPEG has only 8x8 blocks.
        }
        for (final int c in cMap) {
          final int upY = header.jpegUpsamplingY[c];
          final int upX = header.jpegUpsamplingX[c];
          final int groupY = posY - groupPosY;
          final int groupX = posX - groupPosX;
          final int sGroupY = groupY >> upY;
          final int sGroupX = groupX >> upX;
          if (groupY != sGroupY << upY || groupX != sGroupX << upX) {
            continue;
          }
          final int globalBlockY = ((lfLoc.y * lfBlkStride) >> upY) + (posY >> upY);
          final int globalBlockX = ((lfLoc.x * lfBlkStride) >> upX) + (posX >> upX);
          sink.setAcBlock(cMap[c], globalBlockY, globalBlockX, quantizedCoeffs[c], sGroupY << 3, sGroupX << 3, coeffWidth[c]);
          // Chroma (X->Cb via xFromY, B->Cr via bFromY): record the block's
          // 64x64 color-tile CfL factor for later integer-exact inversion.
          if (c == 0 || c == 2) {
            final ModularChannel corr = meta.hfStreamChannels[c == 0 ? 0 : 1];
            final int corrW = corr.width;
            sink.setFactor(cMap[c], globalBlockY, globalBlockX, corr.buffer![(posY >> 3) * corrW + (posX >> 3)]);
          }
        }
      }
    }
  }

  /// Processes dequant hFCoeff at information in a JPEG XL codestream.
  ///
  List<Float32List> dequantHFCoeffAt(int c) => c == 0 ? dequantHFCoeff0 : (c == 1 ? dequantHFCoeff1 : dequantHFCoeff2);

  /// Processes dequant hFCoeff vAt information in a JPEG XL codestream.
  ///
  List<Float32x4List> dequantHFCoeffVAt(int c) => c == 0 ? dequantHFCoeffV0 : (c == 1 ? dequantHFCoeffV1 : dequantHFCoeffV2);

  /// Processes bake dequantized coeffs information in a JPEG XL codestream.
  ///
  void bakeDequantizedCoeffs() {
    _dequantizeHFCoefficients();
    _chromaFromLuma();
    _finalizeLLF();
  }

  /// Public so the lossy encoder can compute the exact same block-context
  /// cluster id the decoder does, without hand-duplicating the formula.
  static int getBlockContext(HfBlockContext hfctx, int c, int orderID, int hfMult, int lfIndex) {
    int idx = (c < 2 ? 1 - c : c) * 13 + orderID;
    idx *= hfctx.qfThresholds.length + 1;
    for (final int t in hfctx.qfThresholds) {
      if (hfMult > t) {
        idx++;
      }
    }
    idx *= hfctx.numLFContexts;
    return hfctx.clusterMap[idx + lfIndex];
  }

  /// Public so the lossy encoder can compute the exact same non-zero-count
  /// context id the decoder does.
  static int getNonZeroContext(HfBlockContext hfctx, int predictedCount, int ctx) {
    int predicted = predictedCount;
    if (predicted > 64) {
      predicted = 64;
    }
    if (predicted < 8) {
      return ctx + hfctx.numClusters * predicted;
    }
    return ctx + hfctx.numClusters * (4 + predicted ~/ 2);
  }

  /// Public so the lossy encoder can compute the exact same per-position
  /// coefficient context id the decoder does (mirrors `_coeffNumNonzeroCtx`
  /// / `_coeffFreqCtx` exactly, without hand-duplicating those tables).
  static int getCoefficientContext(int coefficientIndex, int nonZeroCount, int numBlocks, int prev) {
    int k = coefficientIndex;
    int nonZeroes = nonZeroCount;
    // numBlocks == 1 (a single 8x8-or-smaller transform, the overwhelming
    // common case) makes both divisions identities; skip them.
    if (numBlocks != 1) {
      nonZeroes = (nonZeroes + numBlocks - 1) ~/ numBlocks;
      k ~/= numBlocks;
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

  /// Processes the dequantize hfcoefficients data used by the JPEG XL codec.
  ///
  void _dequantizeHFCoefficients() {
    final OpsinInverseMatrix matrix = frame.globalMetadata.opsinInverseMatrix;
    final FrameHeader header = frame.header;
    final double globalScale = 65536.0 / frame.lfGlobal.globalScale;
    final scaleFactor = <double>[globalScale * math.pow(0.8, header.xqmScale - 2.0).toDouble(), globalScale, globalScale * math.pow(0.8, header.bqmScale - 2.0).toDouble()];
    final HfGlobal hfGlobal = frame.hfGlobal!;
    final List<int> weightsWidth = hfGlobal.weightsWidth;
    final vnum = Float32x4.splat(matrix.quantBiasNumerator);
    final vone = Float32x4.splat(1.0);
    final vzero = Float32x4.zero();
    final vbias = [Float32x4.splat(matrix.quantBias[0]), Float32x4.splat(matrix.quantBias[1]), Float32x4.splat(matrix.quantBias[2])];
    final List<List<double>> qbclut = [
      [-matrix.quantBias[0], 0.0, matrix.quantBias[0]],
      [-matrix.quantBias[1], 0.0, matrix.quantBias[1]],
      [-matrix.quantBias[2], 0.0, matrix.quantBias[2]],
    ];
    final HfMetadata meta = lfg.hfMetadata!;
    for (final int i in includedIndices) {
      final int posY = meta.blockY[i];
      final int posX = meta.blockX[i];
      final TransformType tt = meta.dctSelectAt(posY, posX)!;
      final int groupY = posY - groupPosY;
      final int groupX = posX - groupPosX;
      final bool flip = tt.flip;
      final List<Float32List?> w2 = hfGlobal.flatWeightsFor(tt.parameterIndex);
      final int w3w = weightsWidth[tt.parameterIndex];
      for (var c = 0; c < 3; c++) {
        final int sGroupY = groupY >> header.jpegUpsamplingY[c];
        final int sGroupX = groupX >> header.jpegUpsamplingX[c];
        if (groupY != sGroupY << header.jpegUpsamplingY[c] || groupX != sGroupX << header.jpegUpsamplingX[c]) {
          continue; // subsampled block
        }
        final double sfc = scaleFactor[c] / meta.hfMultiplierAt(posY, posX);
        final int pixelGroupY = sGroupY << 3;
        final int pixelGroupX = sGroupX << 3;
        final int qw = coeffWidth[c];
        if (simdViews && tt.pixelWidth & 3 == 0) {
          // Vector path: LLF positions hold zero coefficients and produce
          // zero here (finalizeLLF overwrites them), so no skip test is
          // needed. quant for |coeff| < 2 is exactly bias * coeff, and
          // flipped transforms read the pre-transposed weights so the
          // access is always row-major with stride pixelWidth.
          final Float32x4List qcV = quantizedCoeffsV[c];
          final List<Float32x4List> dqV = dequantHFCoeffVAt(c);
          final Float32x4List wV = flip ? hfGlobal.weightsFlatTV[tt.parameterIndex][c]! : hfGlobal.weightsFlatV[tt.parameterIndex][c]!;
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
        final Float32List qc = quantizedCoeffs[c];
        final List<Float32List> dq = dequantHFCoeffAt(c);
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

  /// Processes the chroma from luma data used by the JPEG XL codec.
  ///
  void _chromaFromLuma() {
    if (frame.header.isSubsampled) {
      return;
    }
    final LfChannelCorrelation lfc = frame.lfGlobal.lfChanCorr;
    final HfMetadata meta = lfg.hfMetadata!;
    final ModularChannel xFromY = meta.hfStreamChannels[0];
    final ModularChannel bFromY = meta.hfStreamChannels[1];
    final int corrW = xFromY.width;
    final Int32List xFactorHF = xFromY.buffer!;
    final Int32List bFactorHF = bFromY.buffer!;
    final List<Float32List> xFactors = floatMatrix(xFromY.height, corrW);
    final List<Float32List> bFactors = floatMatrix(bFromY.height, corrW);
    final List<Float32List> d0 = dequantHFCoeff0;
    final List<Float32List> d1 = dequantHFCoeff1;
    final List<Float32List> d2 = dequantHFCoeff2;
    for (final int i in includedIndices) {
      final int posY = meta.blockY[i];
      final int posX = meta.blockX[i];
      final TransformType tt = meta.dctSelectAt(posY, posX)!;
      final int pPosY = posY << 3;
      final int pPosX = posX << 3;
      for (var iy = 0; iy < tt.pixelHeight; iy++) {
        final int y = pPosY + iy;
        final int fy = y >> 6;
        final by = fy << 6 == y;
        final Float32List xF = xFactors[fy];
        final Float32List bF = bFactors[fy];
        for (var ix = 0; ix < tt.pixelWidth; ix++) {
          final int x = pPosX + ix;
          final int fx = x >> 6;
          double kX;
          double kB;
          if (by && fx << 6 == x) {
            kX = lfc.baseCorrelationX + xFactorHF[fy * corrW + fx] / lfc.colorFactor;
            kB = lfc.baseCorrelationB + bFactorHF[fy * corrW + fx] / lfc.colorFactor;
            xF[fx] = kX;
            bF[fx] = kB;
          } else {
            kX = xF[fx];
            kB = bF[fx];
          }
          final double dequantY = d1[y & 0xFF][x & 0xFF];
          d0[y & 0xFF][x & 0xFF] += kX * dequantY;
          d2[y & 0xFF][x & 0xFF] += kB * dequantY;
        }
      }
    }
  }

  /// Processes the finalize llf data used by the JPEG XL codec.
  ///
  void _finalizeLLF() {
    final List<Float32List> scratch0 = floatMatrix(32, 32);
    final List<Float32List> scratch1 = floatMatrix(32, 32);
    final FrameHeader header = frame.header;
    final HfMetadata meta = lfg.hfMetadata!;
    for (final int i in includedIndices) {
      final int posY = meta.blockY[i];
      final int posX = meta.blockX[i];
      final TransformType tt = meta.dctSelectAt(posY, posX)!;
      final int groupY = posY - groupPosY;
      final int groupX = posX - groupPosX;
      for (var c = 0; c < 3; c++) {
        final int sGroupY = groupY >> header.jpegUpsamplingY[c];
        final int sGroupX = groupX >> header.jpegUpsamplingX[c];
        if (groupY != sGroupY << header.jpegUpsamplingY[c] || groupX != sGroupX << header.jpegUpsamplingX[c]) {
          continue; // subsampled block
        }
        final int pixelGroupY = sGroupY << 3;
        final int pixelGroupX = sGroupX << 3;
        final int sLfgY = posY >> header.jpegUpsamplingY[c];
        final int sLfgX = posX >> header.jpegUpsamplingX[c];
        final List<Float32List> dqlf = lfg.lfCoeff!.dequantLFCoeffAt(c);
        final List<Float32List> dq = dequantHFCoeffAt(c);
        forwardDCT2D(dqlf, dq, sLfgY, sLfgX, pixelGroupY, pixelGroupX, tt.dctSelectHeight, tt.dctSelectWidth, scratch0, scratch1);
        for (var y = 0; y < tt.dctSelectHeight; y++) {
          final Float32List dqy = dq[y + pixelGroupY];
          for (var x = 0; x < tt.dctSelectWidth; x++) {
            dqy[x + pixelGroupX] *= tt.llfScale[y * tt.dctSelectWidth + x];
          }
        }
      }
    }
  }
}
