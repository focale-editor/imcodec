import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/color/opsin_inverse.dart';
import 'package:imcodec/src/codecs/jpeg_xl/color/transfer_function.dart';

/// Processes the cbrt data used by the JPEG XL codec.
///
double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

/// Processes the invert3x3 data used by the JPEG XL codec.
///
List<double> _invert3x3(List<double> m) {
  final double a = m[0];
  final double b = m[1];
  final double c = m[2];
  final double d = m[3];
  final double e = m[4];
  final double f = m[5];
  final double g = m[6];
  final double h = m[7];
  final double i = m[8];
  final double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  final double invDet = 1.0 / det;
  return [
    (e * i - f * h) * invDet, (c * h - b * i) * invDet,
    (b * f - c * e) * invDet, //
    (f * g - d * i) * invDet, (a * i - c * g) * invDet,
    (c * d - a * f) * invDet, //
    (d * h - e * g) * invDet, (b * g - a * h) * invDet,
    (a * e - b * d) * invDet, //
  ];
}

/// Forward XYB transform: the exact inverse of
/// [OpsinInverseMatrix.invertXyb] with the default matrix/bias and
/// `intensityTarget == 255` (`itScale == 1`), which is what an encoder that
/// writes `default_matrix = true` (the only mode this encoder supports)
/// always gets on decode.
final class XybForward {
  /// Processes the matrix data used by the JPEG XL codec.
  ///
  static const _matrix = OpsinInverseMatrix();

  /// Stores the inv state used internally by the JPEG XL codec.
  ///
  final List<double> _inv;

  /// Creates Xyb forward data for JPEG XL processing.
  ///
  XybForward() : _inv = _invert3x3(_matrix.matrix);

  /// Converts linear-light RGB rows (the same domain
  /// [OpsinInverseMatrix.invertXyb] produces, roughly `[0, 1]` for SDR) in
  /// place into XYB rows.
  void forward(List<Float32List> rRows, List<Float32List> gRows, List<Float32List> bRows) {
    final double ob0 = _matrix.opsinBias[0];
    final double ob1 = _matrix.opsinBias[1];
    final double ob2 = _matrix.opsinBias[2];
    final double cob0 = _cbrt(ob0);
    final double cob1 = _cbrt(ob1);
    final double cob2 = _cbrt(ob2);
    final List<double> inv = _inv;
    for (var y = 0; y < rRows.length; y++) {
      final Float32List rRow = rRows[y];
      final Float32List gRow = gRows[y];
      final Float32List bRow = bRows[y];
      for (var x = 0; x < rRow.length; x++) {
        final double r = rRow[x];
        final double g = gRow[x];
        final double bl = bRow[x];
        final double mixL = inv[0] * r + inv[1] * g + inv[2] * bl;
        final double mixM = inv[3] * r + inv[4] * g + inv[5] * bl;
        final double mixS = inv[6] * r + inv[7] * g + inv[8] * bl;
        final double gammaL = _cbrt(mixL - ob0);
        final double gammaM = _cbrt(mixM - ob1);
        final double gammaS = _cbrt(mixS - ob2);
        rRow[x] = 0.5 * (gammaL - gammaM + cob0 - cob1); // X
        gRow[x] = 0.5 * (gammaL + gammaM + cob0 + cob1); // Y
        bRow[x] = gammaS + cob2; // B
      }
    }
  }

  /// Converts 8-bit sRGB samples (0..255) in place into linear-light values
  /// suitable for [forward], via the sRGB EOTF.
  static void srgbToLinear(List<Float32List> rows) {
    final TransferFunction tf = TransferFunction.forTransfer(ColorFlags.tfSrgb);
    for (final row in rows) {
      for (var x = 0; x < row.length; x++) {
        row[x] = tf.toLinear(row[x] / 255.0);
      }
    }
  }
}
