import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/color/opsin_inverse.dart';
import 'package:imcodec/src/codecs/jpeg_xl/color/transfer_function.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';

/// Returns the inverse of a row-major three-by-three [matrix].
List<double> _invertThreeByThreeMatrix(List<double> matrix) {
  final double matrix00 = matrix[0];
  final double matrix01 = matrix[1];
  final double matrix02 = matrix[2];
  final double matrix10 = matrix[3];
  final double matrix11 = matrix[4];
  final double matrix12 = matrix[5];
  final double matrix20 = matrix[6];
  final double matrix21 = matrix[7];
  final double matrix22 = matrix[8];
  final double determinant = matrix00 * (matrix11 * matrix22 - matrix12 * matrix21) - matrix01 * (matrix10 * matrix22 - matrix12 * matrix20) + matrix02 * (matrix10 * matrix21 - matrix11 * matrix20);
  final double inverseDeterminant = 1.0 / determinant;
  return [
    (matrix11 * matrix22 - matrix12 * matrix21) * inverseDeterminant,
    (matrix02 * matrix21 - matrix01 * matrix22) * inverseDeterminant,
    (matrix01 * matrix12 - matrix02 * matrix11) * inverseDeterminant,
    (matrix12 * matrix20 - matrix10 * matrix22) * inverseDeterminant,
    (matrix00 * matrix22 - matrix02 * matrix20) * inverseDeterminant,
    (matrix02 * matrix10 - matrix00 * matrix12) * inverseDeterminant,
    (matrix10 * matrix21 - matrix11 * matrix20) * inverseDeterminant,
    (matrix01 * matrix20 - matrix00 * matrix21) * inverseDeterminant,
    (matrix00 * matrix11 - matrix01 * matrix10) * inverseDeterminant,
  ];
}

/// Converts linear RGB samples to JPEG XL's XYB color space.
/// This transform is the exact inverse of
/// [OpsinInverseMatrix.invertXyb] with the default matrix/bias and
/// `intensityTarget == 255` (`itScale == 1`), which is what an encoder that
/// writes `default_matrix = true` (the only mode this encoder supports)
/// always gets on decode.
final class XybConverter {
  /// Default opsin matrix whose forward transform is required here.
  static const OpsinInverseMatrix _opsinMatrix = OpsinInverseMatrix();

  /// Forward RGB-to-opsin mixing matrix.
  final List<double> _inverseMatrix;

  /// Creates a converter using the default JPEG XL opsin matrix.
  XybConverter() : _inverseMatrix = _invertThreeByThreeMatrix(_opsinMatrix.matrix);

  /// Converts linear-light RGB rows (the same domain
  /// [OpsinInverseMatrix.invertXyb] produces, roughly `[0, 1]` for SDR) in
  /// place into XYB rows.
  void convertInPlace(List<Float32List> redRows, List<Float32List> greenRows, List<Float32List> blueRows) {
    final double firstOpsinBias = _opsinMatrix.opsinBias[0];
    final double secondOpsinBias = _opsinMatrix.opsinBias[1];
    final double thirdOpsinBias = _opsinMatrix.opsinBias[2];
    final double firstBiasCubeRoot = realCubeRoot(firstOpsinBias);
    final double secondBiasCubeRoot = realCubeRoot(secondOpsinBias);
    final double thirdBiasCubeRoot = realCubeRoot(thirdOpsinBias);
    final List<double> inverseMatrix = _inverseMatrix;
    for (int rowIndex = 0; rowIndex < redRows.length; rowIndex++) {
      final Float32List redRow = redRows[rowIndex];
      final Float32List greenRow = greenRows[rowIndex];
      final Float32List blueRow = blueRows[rowIndex];
      for (int columnIndex = 0; columnIndex < redRow.length; columnIndex++) {
        final double red = redRow[columnIndex];
        final double green = greenRow[columnIndex];
        final double blue = blueRow[columnIndex];
        final double longConeMix = inverseMatrix[0] * red + inverseMatrix[1] * green + inverseMatrix[2] * blue;
        final double mediumConeMix = inverseMatrix[3] * red + inverseMatrix[4] * green + inverseMatrix[5] * blue;
        final double shortConeMix = inverseMatrix[6] * red + inverseMatrix[7] * green + inverseMatrix[8] * blue;
        final double longConeResponse = realCubeRoot(longConeMix - firstOpsinBias);
        final double mediumConeResponse = realCubeRoot(mediumConeMix - secondOpsinBias);
        final double shortConeResponse = realCubeRoot(shortConeMix - thirdOpsinBias);
        redRow[columnIndex] = 0.5 * (longConeResponse - mediumConeResponse + firstBiasCubeRoot - secondBiasCubeRoot); // X
        greenRow[columnIndex] = 0.5 * (longConeResponse + mediumConeResponse + firstBiasCubeRoot + secondBiasCubeRoot); // Y
        blueRow[columnIndex] = shortConeResponse + thirdBiasCubeRoot; // B
      }
    }
  }

  /// Converts 8-bit sRGB samples (0..255) in place into linear-light values
  /// suitable for [convertInPlace], via the sRGB EOTF.
  static void convertSrgbPlaneToLinear(List<Float32List> rows) {
    final TransferFunction transferFunction = TransferFunction.forTransfer(ColorEncodingConstants.srgbTransferFunction);
    for (final Float32List row in rows) {
      for (int columnIndex = 0; columnIndex < row.length; columnIndex++) {
        row[columnIndex] = transferFunction.toLinear(row[columnIndex] / 255.0);
      }
    }
  }
}
