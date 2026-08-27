import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';

/// Bradford cone-response matrix used for chromatic adaptation.
const List<List<double>> _bradfordMatrix = [
  [0.8951, 0.2664, -0.1614],
  [-0.7502, 1.7135, 0.0367],
  [0.0389, -0.0685, 1.0296],
];

/// Multiplies two row-major three-by-three matrices.
List<List<double>> multiplyThreeByThreeMatrices(List<List<double>> left, List<List<double>> right) {
  final List<List<double>> result = List.generate(3, (_) => List<double>.filled(3, 0));
  for (int row = 0; row < 3; row++) {
    for (int column = 0; column < 3; column++) {
      double total = 0.0;
      for (int innerIndex = 0; innerIndex < 3; innerIndex++) {
        total += left[row][innerIndex] * right[innerIndex][column];
      }
      result[row][column] = total;
    }
  }
  return result;
}

/// Multiplies a row-major three-by-three [matrix] by a three-value [vector].
List<double> multiplyThreeByThreeMatrixAndVector(List<List<double>> matrix, List<double> vector) => [
  for (int row = 0; row < 3; row++) matrix[row][0] * vector[0] + matrix[row][1] * vector[1] + matrix[row][2] * vector[2],
];

/// Returns the inverse of [matrix], or `null` when it is singular.
List<List<double>>? invertThreeByThreeMatrix(List<List<double>> matrix) {
  double determinant = 0.0;
  for (int column = 0; column < 3; column++) {
    final int nextColumn = (column + 1) % 3;
    final int finalColumn = (column + 2) % 3;
    determinant += matrix[column][0] * matrix[nextColumn][1] * matrix[finalColumn][2] - matrix[column][0] * matrix[nextColumn][2] * matrix[finalColumn][1];
  }
  if (determinant == 0) {
    return null;
  }
  final double inverseDeterminant = 1.0 / determinant;
  final List<List<double>> inverse = List.generate(3, (_) => List<double>.filled(3, 0));
  for (int column = 0; column < 3; column++) {
    for (int row = 0; row < 3; row++) {
      final int nextColumn = (column + 1) % 3;
      final int finalColumn = (column + 2) % 3;
      final int nextRow = (row + 1) % 3;
      final int finalRow = (row + 2) % 3;
      inverse[row][column] = (matrix[nextColumn][nextRow] * matrix[finalColumn][finalRow] - matrix[finalColumn][nextRow] * matrix[nextColumn][finalRow]) * inverseDeterminant;
    }
  }
  return inverse;
}

/// Returns a three-by-three identity matrix.
List<List<double>> threeByThreeIdentityMatrix() => [
  [1, 0, 0],
  [0, 1, 0],
  [0, 0, 1],
];

/// Converts a CIE xy [chromaticity] to normalized XYZ tristimulus values.
List<double> _chromaticityToXyz(CieXy chromaticity) {
  final double inverseY = 1.0 / chromaticity.y;
  return [chromaticity.x * inverseY, 1.0, (1.0 - chromaticity.x - chromaticity.y) * inverseY];
}

/// Builds a Bradford adaptation matrix between two white points.
List<List<double>> _whitePointAdaptationMatrix(CieXy? targetWhitePoint, CieXy? currentWhitePoint) {
  final CieXy target = targetWhitePoint ?? ColorEncodingConstants.whitePointCoordinates(ColorEncodingConstants.d50WhitePoint)!;
  final CieXy current = currentWhitePoint ?? ColorEncodingConstants.whitePointCoordinates(ColorEncodingConstants.d50WhitePoint)!;
  final List<double> lmsCurrent = multiplyThreeByThreeMatrixAndVector(_bradfordMatrix, _chromaticityToXyz(current));
  final List<double> lmsTarget = multiplyThreeByThreeMatrixAndVector(_bradfordMatrix, _chromaticityToXyz(target));
  final List<List<double>> coneScale = List.generate(3, (_) => List<double>.filled(3, 0));
  for (int channel = 0; channel < 3; channel++) {
    coneScale[channel][channel] = lmsTarget[channel] / lmsCurrent[channel];
  }
  final List<List<double>> bradfordInverse = invertThreeByThreeMatrix(_bradfordMatrix)!;
  return multiplyThreeByThreeMatrices(multiplyThreeByThreeMatrices(bradfordInverse, coneScale), _bradfordMatrix);
}

/// Builds the RGB-to-XYZ matrix for [primaries] and [whitePoint].
List<List<double>> _primariesToXyzMatrix(CiePrimaries primaries, CieXy? whitePoint) {
  final CieXy resolvedWhitePoint = whitePoint ?? ColorEncodingConstants.whitePointCoordinates(ColorEncodingConstants.d50WhitePoint)!;
  final List<List<double>> primaryTristimulusValues = [_chromaticityToXyz(primaries.red), _chromaticityToXyz(primaries.green), _chromaticityToXyz(primaries.blue)];
  // Transpose.
  final List<List<double>> primariesMatrix = List.generate(3, (row) => List<double>.generate(3, (column) => primaryTristimulusValues[column][row]));
  final List<List<double>> inversePrimaries = invertThreeByThreeMatrix(primariesMatrix)!;
  final List<double> channelScales = multiplyThreeByThreeMatrixAndVector(inversePrimaries, _chromaticityToXyz(resolvedWhitePoint));
  final List<List<double>> scaleMatrix = [
    [channelScales[0], 0.0, 0.0],
    [0.0, channelScales[1], 0.0],
    [0.0, 0.0, channelScales[2]],
  ];
  return multiplyThreeByThreeMatrices(primariesMatrix, scaleMatrix);
}

/// Builds a linear-RGB conversion matrix between two color encodings.
List<List<double>> colorConversionMatrix(CiePrimaries targetPrimaries, CieXy targetWhitePoint, CiePrimaries currentPrimaries, CieXy currentWhitePoint) {
  if (targetPrimaries.matches(currentPrimaries) && targetWhitePoint.matches(currentWhitePoint)) {
    return threeByThreeIdentityMatrix();
  }
  List<List<double>>? whitePointConversion;
  if (!targetWhitePoint.matches(currentWhitePoint)) {
    whitePointConversion = _whitePointAdaptationMatrix(targetWhitePoint, currentWhitePoint);
  }
  final List<List<double>> forward = _primariesToXyzMatrix(currentPrimaries, currentWhitePoint);
  final List<List<double>> reverse = invertThreeByThreeMatrix(_primariesToXyzMatrix(targetPrimaries, targetWhitePoint))!;
  List<List<double>> result = forward;
  if (whitePointConversion != null) {
    result = multiplyThreeByThreeMatrices(whitePointConversion, result);
  }
  return multiplyThreeByThreeMatrices(reverse, result);
}
