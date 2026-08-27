import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/color/color_management.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The XYB → linear RGB opsin inverse matrix bundle.
final class OpsinInverseMatrix {
  /// Specification constant identifying default matrix.
  static const _defaultMatrix = [
    11.031566901960783, -9.866943921568629, -0.16462299647058826, //
    -3.254147380392157, 4.418770392156863, -0.16462299647058826, //
    -3.6588512862745097, 2.7129230470588235, 1.9459282392156863,
  ];

  /// Specification constant identifying default opsin bias.
  static const _defaultOpsinBias = [-0.0037930732552754493, -0.0037930732552754493, -0.0037930732552754493];

  /// Specification constant identifying default quant bias.
  static const _defaultQuantBias = [0.945349926692846, 0.9299455010825141, 0.9500648966626564];

  /// Specification constant identifying default quant bias numerator.
  static const _defaultQuantBiasNumerator = 0.145;

  /// Row-major 3x3 matrix.
  final List<double> matrix;

  /// Bias subtracted before the opsin cube operation.
  final List<double> opsinBias;

  /// Per-channel bias used by quantization-field estimation.
  final List<double> quantBias;

  /// Shared numerator used by quantization-field estimation.
  final double quantBiasNumerator;

  /// Creates an opsin inverse matrix.
  const OpsinInverseMatrix() : matrix = _defaultMatrix, opsinBias = _defaultOpsinBias, quantBias = _defaultQuantBias, quantBiasNumerator = _defaultQuantBiasNumerator;

  /// Reads this structure from the bitstream.
  factory OpsinInverseMatrix.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return const OpsinInverseMatrix();
    }
    final matrix = List<double>.generate(9, (_) => reader.readF16());
    final opsinBias = List<double>.generate(3, (_) => reader.readF16());
    final quantBias = List<double>.generate(3, (_) => reader.readF16());
    final double quantBiasNumerator = reader.readF16();
    return OpsinInverseMatrix._(matrix: matrix, opsinBias: opsinBias, quantBias: quantBias, quantBiasNumerator: quantBiasNumerator);
  }

  /// Creates an opsin inverse matrix.
  const OpsinInverseMatrix._({
    required this.matrix,
    required this.opsinBias,
    required this.quantBias,
    required this.quantBiasNumerator,
  });

  /// Primaries/white point this matrix targets before any conversion.
  CiePrimaries get primaries => ColorEncodingConstants.primariesCoordinates(ColorEncodingConstants.srgbPrimaries)!;

  /// D65 white point targeted by the default matrix.
  CieXy get whitePoint => ColorEncodingConstants.whitePointCoordinates(ColorEncodingConstants.d65WhitePoint)!;

  /// Returns this matrix adapted to produce linear RGB with the given
  /// primaries and white point (instead of sRGB/D65).
  OpsinInverseMatrix getMatrix(CiePrimaries targetPrim, CieXy targetWP) {
    final List<List<double>> conversion = colorConversionMatrix(targetPrim, targetWP, primaries, whitePoint);
    final List<List<double>> m = [
      [matrix[0], matrix[1], matrix[2]],
      [matrix[3], matrix[4], matrix[5]],
      [matrix[6], matrix[7], matrix[8]],
    ];
    final List<List<double>> adapted = multiplyThreeByThreeMatrices(conversion, m);
    return OpsinInverseMatrix._(matrix: [for (var y = 0; y < 3; y++) ...adapted[y]], opsinBias: opsinBias, quantBias: quantBias, quantBiasNumerator: quantBiasNumerator);
  }

  /// Inverts XYB to linear RGB in place over the given channel rows
  /// (X, Y, B order in; R, G, B out).
  void invertXyb(List<Float32List> xRows, List<Float32List> yRows, List<Float32List> bRows, double intensityTarget) {
    final double itScale = 255.0 / intensityTarget;
    final scaledMatrix = Float32List(9);
    for (var i = 0; i < 9; i++) {
      scaledMatrix[i] = matrix[i] * itScale;
    }
    final double ob0 = opsinBias[0];
    final double ob1 = opsinBias[1];
    final double ob2 = opsinBias[2];
    final double cob0 = -realCubeRoot(opsinBias[0]);
    final double cob1 = -realCubeRoot(opsinBias[1]);
    final double cob2 = -realCubeRoot(opsinBias[2]);
    final vcob0 = Float32x4.splat(cob0);
    final vcob1 = Float32x4.splat(cob1);
    final vcob2 = Float32x4.splat(cob2);
    final vob0 = Float32x4.splat(ob0);
    final vob1 = Float32x4.splat(ob1);
    final vob2 = Float32x4.splat(ob2);
    final m0 = Float32x4.splat(scaledMatrix[0]);
    final m1 = Float32x4.splat(scaledMatrix[1]);
    final m2 = Float32x4.splat(scaledMatrix[2]);
    final m3 = Float32x4.splat(scaledMatrix[3]);
    final m4 = Float32x4.splat(scaledMatrix[4]);
    final m5 = Float32x4.splat(scaledMatrix[5]);
    final m6 = Float32x4.splat(scaledMatrix[6]);
    final m7 = Float32x4.splat(scaledMatrix[7]);
    final m8 = Float32x4.splat(scaledMatrix[8]);
    for (var y = 0; y < xRows.length; y++) {
      final Float32List xRow = xRows[y];
      final Float32List yRow = yRows[y];
      final Float32List bRow = bRows[y];
      final int w = xRow.length;
      final int w4 = w >> 2;
      final xv = Float32x4List.view(xRow.buffer, xRow.offsetInBytes, w4);
      final yv = Float32x4List.view(yRow.buffer, yRow.offsetInBytes, w4);
      final bv = Float32x4List.view(bRow.buffer, bRow.offsetInBytes, w4);
      for (var i = 0; i < w4; i++) {
        final Float32x4 xybX = xv[i];
        final Float32x4 xybY = yv[i];
        final Float32x4 xybB = bv[i];
        final Float32x4 gammaL = xybY + xybX + vcob0;
        final Float32x4 gammaM = xybY - xybX + vcob1;
        final Float32x4 gammaS = xybB + vcob2;
        final Float32x4 mixL = gammaL * gammaL * gammaL + vob0;
        final Float32x4 mixM = gammaM * gammaM * gammaM + vob1;
        final Float32x4 mixS = gammaS * gammaS * gammaS + vob2;
        xv[i] = m0 * mixL + m1 * mixM + m2 * mixS;
        yv[i] = m3 * mixL + m4 * mixM + m5 * mixS;
        bv[i] = m6 * mixL + m7 * mixM + m8 * mixS;
      }
      for (int x = w4 << 2; x < w; x++) {
        final double xybX = xRow[x];
        final double xybY = yRow[x];
        final double xybB = bRow[x];
        final double gammaL = xybY + xybX + cob0;
        final double gammaM = xybY - xybX + cob1;
        final double gammaS = xybB + cob2;
        final double mixL = gammaL * gammaL * gammaL + ob0;
        final double mixM = gammaM * gammaM * gammaM + ob1;
        final double mixS = gammaS * gammaS * gammaS + ob2;
        xRow[x] = scaledMatrix[0] * mixL + scaledMatrix[1] * mixM + scaledMatrix[2] * mixS;
        yRow[x] = scaledMatrix[3] * mixL + scaledMatrix[4] * mixM + scaledMatrix[5] * mixS;
        bRow[x] = scaledMatrix[6] * mixL + scaledMatrix[7] * mixM + scaledMatrix[8] * mixS;
      }
    }
  }
}
