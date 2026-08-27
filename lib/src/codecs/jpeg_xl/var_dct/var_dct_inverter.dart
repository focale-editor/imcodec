import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/afv_basis.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/dct.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_coefficients.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_metadata.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Copies a rectangular transform block into its output position.
void _copyTransformBlock(List<Float32List> block, List<Float32List> buffer, int inputOriginY, int inputOriginX, int outputOriginY, int outputOriginX, int height, int width) {
  for (var y = 0; y < height; y++) {
    buffer[y + outputOriginY].setRange(outputOriginX, outputOriginX + width, block[y + inputOriginY], inputOriginX);
  }
}

/// Reconstructs one asymmetric-frequency-varying transform block.
void _invertAfv(
  List<Float32List> coefficients,
  List<Float32List> buffer,
  TransformType transformType,
  int coefficientOriginY,
  int coefficientOriginX,
  int outputOriginY,
  int outputOriginX,
  List<Float32List> firstScratch,
  List<Float32List> secondScratch,
  List<Float32List> thirdScratch,
  List<Float32List> fourthScratch,
) {
  firstScratch[0][0] =
      (coefficients[coefficientOriginY][coefficientOriginX] + coefficients[coefficientOriginY + 1][coefficientOriginX] + coefficients[coefficientOriginY][coefficientOriginX + 1]) * 4.0;
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
      firstScratch[iy][ix] = coefficients[coefficientOriginY + iy * 2][coefficientOriginX + ix * 2];
    }
  }
  final flipY = transformType.type == 16 || transformType.type == 17 ? 1 : 0; // AFV2, AFV3
  final flipX = transformType.type == 15 || transformType.type == 17 ? 1 : 0; // AFV1, AFV3

  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 4; ix++) {
      var sample = 0.0;
      for (var j = 0; j < 16; j++) {
        final int jy = j >> 2;
        final int jx = j & 3;
        sample += firstScratch[jy][jx] * afvBasis[j * 16 + iy * 4 + ix];
      }
      secondScratch[iy][ix] = sample;
    }
  }
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 4; ix++) {
      buffer[outputOriginY + flipY * 4 + iy][outputOriginX + flipX * 4 + ix] = secondScratch[flipY == 1 ? 3 - iy : iy][flipX == 1 ? 3 - ix : ix];
    }
  }
  // SPEC: watch signs here.
  firstScratch[0][0] = coefficients[coefficientOriginY][coefficientOriginX] + coefficients[coefficientOriginY + 1][coefficientOriginX] - coefficients[coefficientOriginY][coefficientOriginX + 1];
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
      firstScratch[iy][ix] = coefficients[coefficientOriginY + iy * 2][coefficientOriginX + ix * 2 + 1];
    }
  }
  inverseDct2d(firstScratch, secondScratch, 0, 0, 0, 0, 4, 4, thirdScratch, fourthScratch, false);
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 4; ix++) {
      // Transposed intentionally.
      buffer[outputOriginY + flipY * 4 + iy][outputOriginX + (flipX == 1 ? 0 : 4) + ix] = secondScratch[ix][iy];
    }
  }
  firstScratch[0][0] = coefficients[coefficientOriginY][coefficientOriginX] - coefficients[coefficientOriginY + 1][coefficientOriginX];
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
      firstScratch[iy][ix] = coefficients[coefficientOriginY + 1 + iy * 2][coefficientOriginX + ix];
    }
  }
  inverseDct2d(firstScratch, secondScratch, 0, 0, 0, 0, 4, 8, thirdScratch, fourthScratch, false);
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 8; ix++) {
      buffer[outputOriginY + (flipY == 1 ? 0 : 4) + iy][outputOriginX + ix] = secondScratch[iy][ix];
    }
  }
}

/// Applies the auxiliary two-by-two inverse transform to one coefficient block.
void _applyAuxiliaryDct2(List<Float32List> coefficients, List<Float32List> result, int pY, int pX, int psY, int psX, int s) {
  _copyTransformBlock(coefficients, result, pY, pX, psY, psX, 8, 8);
  final int num = s ~/ 2;
  for (var iy = 0; iy < num; iy++) {
    for (var ix = 0; ix < num; ix++) {
      final double c00 = coefficients[pY + iy][pX + ix];
      final double c01 = coefficients[pY + iy][pX + ix + num];
      final double c10 = coefficients[pY + iy + num][pX + ix];
      final double c11 = coefficients[pY + iy + num][pX + ix + num];
      result[psY + iy * 2][psX + ix * 2] = c00 + c01 + c10 + c11;
      result[psY + iy * 2][psX + ix * 2 + 1] = c00 + c01 - c10 - c11;
      result[psY + iy * 2 + 1][psX + ix * 2] = c00 - c01 + c10 - c11;
      result[psY + iy * 2 + 1][psX + ix * 2 + 1] = c00 - c01 - c10 + c11;
    }
  }
}

/// Reconstructs every variable-DCT block in one coding group.
/// Coefficients from a previous progressive pass are accumulated before the
/// current pass is dequantized and transformed into the frame buffers.
void invertVarDctGroup(
  HighFrequencyCoefficients highFrequencyCoefficients,
  HighFrequencyCoefficients? previousPassCoefficients,
  List<Float32List> firstFrameBuffer,
  List<Float32List> secondFrameBuffer,
  List<Float32List> thirdFrameBuffer,
  List<Float32List> firstScratch,
  List<Float32List> secondScratch,
  List<Float32List> thirdScratch,
  List<Float32List> fourthScratch,
  List<Float32List> fifthScratch,
  List<Float32x4List>? firstVectorFrameBuffer,
  List<Float32x4List>? secondVectorFrameBuffer,
  List<Float32x4List>? thirdVectorFrameBuffer,
) {
  final Frame frame = highFrequencyCoefficients.frame;
  final FrameHeader header = frame.header;
  final HighFrequencyMetadata meta = highFrequencyCoefficients.lowFrequencyGroup.highFrequencyMetadata!;

  if (previousPassCoefficients != null) {
    for (final int i in highFrequencyCoefficients.includedIndices) {
      final int posY = meta.blockRows[i];
      final int posX = meta.blockColumns[i];
      final TransformType transformType = meta.transformTypeAt(posY, posX)!;
      final int groupY = posY - highFrequencyCoefficients.groupOriginY;
      final int groupX = posX - highFrequencyCoefficients.groupOriginX;
      for (var c = 0; c < 3; c++) {
        final int sGroupY = groupY >> header.jpegVerticalUpsamplingShift[c];
        final int sGroupX = groupX >> header.jpegHorizontalUpsamplingShift[c];
        if (sGroupY << header.jpegVerticalUpsamplingShift[c] != groupY || sGroupX << header.jpegHorizontalUpsamplingShift[c] != groupX) {
          continue;
        }
        final int pixelY = sGroupY << 3;
        final int pixelX = sGroupX << 3;
        final Float32List qc = highFrequencyCoefficients.quantizedCoefficients[c];
        final Float32List pqc = previousPassCoefficients.quantizedCoefficients[c];
        final int qw = highFrequencyCoefficients.coefficientWidth[c];
        for (var iy = 0; iy < transformType.pixelHeight; iy++) {
          final int base = (pixelY + iy) * qw + pixelX;
          for (var ix = 0; ix < transformType.pixelWidth; ix++) {
            qc[base + ix] += pqc[base + ix];
          }
        }
      }
    }
  }

  highFrequencyCoefficients.bakeDequantizedCoefficients();
  final ({int x, int y}) groupLoc = frame.getGroupLocation(highFrequencyCoefficients.groupId);
  final int groupLocY = groupLoc.y << 8;
  final int groupLocX = groupLoc.x << 8;

  for (final int i in highFrequencyCoefficients.includedIndices) {
    final int posY = meta.blockRows[i];
    final int posX = meta.blockColumns[i];
    final TransformType transformType = meta.transformTypeAt(posY, posX)!;
    final int groupY = posY - highFrequencyCoefficients.groupOriginY;
    final int groupX = posX - highFrequencyCoefficients.groupOriginX;
    for (var c = 0; c < 3; c++) {
      final int sGroupY = groupY >> header.jpegVerticalUpsamplingShift[c];
      final int sGroupX = groupX >> header.jpegHorizontalUpsamplingShift[c];
      if (sGroupY << header.jpegVerticalUpsamplingShift[c] != groupY || sGroupX << header.jpegHorizontalUpsamplingShift[c] != groupX) {
        continue;
      }
      final int coefficientOriginY = sGroupY << 3;
      final int coefficientOriginX = sGroupX << 3;
      final int outputOriginY = coefficientOriginY + (groupLocY >> header.jpegVerticalUpsamplingShift[c]);
      final int outputOriginX = coefficientOriginX + (groupLocX >> header.jpegHorizontalUpsamplingShift[c]);
      final List<Float32List> cc = highFrequencyCoefficients.dequantizedHighFrequencyCoefficientsAt(c);
      final fb = c == 0 ? firstFrameBuffer : (c == 1 ? secondFrameBuffer : thirdFrameBuffer);
      switch (transformType.transformMethod) {
        case TransformMethod.dct:
          if (transformType.pixelHeight == 8 && transformType.pixelWidth == 8 && firstVectorFrameBuffer != null && highFrequencyCoefficients.hasSimdViews) {
            inverseDct8x8Simd(
              highFrequencyCoefficients.dequantizedHighFrequencyCoefficientsSimdAt(c),
              c == 0 ? firstVectorFrameBuffer : (c == 1 ? secondVectorFrameBuffer! : thirdVectorFrameBuffer!),
              coefficientOriginY,
              coefficientOriginX >> 2,
              outputOriginY,
              outputOriginX >> 2,
            );
          } else if (firstVectorFrameBuffer != null && highFrequencyCoefficients.hasSimdViews) {
            inverseDct2dSimd(
              highFrequencyCoefficients.dequantizedHighFrequencyCoefficientsSimdAt(c),
              c == 0 ? firstVectorFrameBuffer : (c == 1 ? secondVectorFrameBuffer! : thirdVectorFrameBuffer!),
              coefficientOriginY,
              coefficientOriginX >> 2,
              outputOriginY,
              outputOriginX >> 2,
              transformType.pixelHeight,
              transformType.pixelWidth,
            );
          } else {
            inverseDct2d(cc, fb, coefficientOriginY, coefficientOriginX, outputOriginY, outputOriginX, transformType.pixelHeight, transformType.pixelWidth, firstScratch, secondScratch, false);
          }
        case TransformMethod.dct8x4:
          final double coeff0 = cc[coefficientOriginY][coefficientOriginX];
          final double coeff1 = cc[coefficientOriginY + 1][coefficientOriginX];
          final List<double> lfs = [coeff0 + coeff1, coeff0 - coeff1];
          for (var x = 0; x < 2; x++) {
            firstScratch[0][0] = lfs[x];
            for (var iy = 0; iy < 4; iy++) {
              for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
                firstScratch[iy][ix] = cc[coefficientOriginY + x + iy * 2][coefficientOriginX + ix];
              }
            }
            inverseDct2d(firstScratch, fb, 0, 0, outputOriginY, outputOriginX + (x << 2), 4, 8, secondScratch, thirdScratch, true);
          }
        case TransformMethod.dct4x8:
          final double coeff0 = cc[coefficientOriginY][coefficientOriginX];
          final double coeff1 = cc[coefficientOriginY + 1][coefficientOriginX];
          final List<double> lfs = [coeff0 + coeff1, coeff0 - coeff1];
          for (var y = 0; y < 2; y++) {
            firstScratch[0][0] = lfs[y];
            for (var iy = 0; iy < 4; iy++) {
              for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
                firstScratch[iy][ix] = cc[coefficientOriginY + y + iy * 2][coefficientOriginX + ix];
              }
            }
            inverseDct2d(firstScratch, fb, 0, 0, outputOriginY + (y << 2), outputOriginX, 4, 8, secondScratch, thirdScratch, false);
          }
        case TransformMethod.afv:
          _invertAfv(cc, fb, transformType, coefficientOriginY, coefficientOriginX, outputOriginY, outputOriginX, firstScratch, secondScratch, thirdScratch, fourthScratch);
        case TransformMethod.dct2:
          _applyAuxiliaryDct2(cc, firstScratch, coefficientOriginY, coefficientOriginX, 0, 0, 2);
          _applyAuxiliaryDct2(firstScratch, secondScratch, 0, 0, 0, 0, 4);
          _applyAuxiliaryDct2(secondScratch, fb, 0, 0, outputOriginY, outputOriginX, 8);
        case TransformMethod.hornuss:
          _applyAuxiliaryDct2(cc, secondScratch, coefficientOriginY, coefficientOriginX, 0, 0, 2);
          for (var y = 0; y < 2; y++) {
            for (var x = 0; x < 2; x++) {
              final double blockLowestFrequency = secondScratch[y][x];
              var residual = 0.0;
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
                  residual += cc[coefficientOriginY + y + iy * 2][coefficientOriginX + x + ix * 2];
                }
              }
              firstScratch[4 * y + 1][4 * x + 1] = blockLowestFrequency - residual * 0.0625;
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = 0; ix < 4; ix++) {
                  if (ix == 1 && iy == 1) {
                    continue;
                  }
                  firstScratch[y * 4 + iy][x * 4 + ix] = cc[coefficientOriginY + y + iy * 2][coefficientOriginX + x + ix * 2] + firstScratch[4 * y + 1][4 * x + 1];
                }
              }
              firstScratch[4 * y][4 * x] = cc[coefficientOriginY + y + 2][coefficientOriginX + x + 2] + firstScratch[4 * y + 1][4 * x + 1];
            }
          }
          _copyTransformBlock(firstScratch, fb, 0, 0, outputOriginY, outputOriginX, transformType.pixelHeight, transformType.pixelWidth);
        case TransformMethod.dct4:
          _applyAuxiliaryDct2(cc, fifthScratch, coefficientOriginY, coefficientOriginX, 0, 0, 2);
          for (var y = 0; y < 2; y++) {
            for (var x = 0; x < 2; x++) {
              firstScratch[0][0] = fifthScratch[y][x];
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
                  firstScratch[iy][ix] = cc[coefficientOriginY + y + iy * 2][coefficientOriginX + x + ix * 2];
                }
              }
              inverseDct2d(firstScratch, secondScratch, 0, 0, 0, 0, 4, 4, thirdScratch, fourthScratch, true);
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = 0; ix < 4; ix++) {
                  fb[outputOriginY + 4 * y + iy][outputOriginX + 4 * x + ix] = secondScratch[iy][ix];
                }
              }
            }
          }
        default:
          throw UnsupportedError('transform not implemented: $transformType');
      }
    }
  }
}
