import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';

/// Minimal color management: white-point adaptation and primaries
/// conversion matrices (all math in doubles, 3x3 row-major lists).

const _bradford = [
  [0.8951, 0.2664, -0.1614],
  [-0.7502, 1.7135, 0.0367],
  [0.0389, -0.0685, 1.0296],
];

/// Processes matrix multiply3 information in a JPEG XL codestream.
///
List<List<double>> matrixMultiply3(List<List<double>> left, List<List<double>> right) {
  final List<List<double>> result = List.generate(3, (_) => List<double>.filled(3, 0));
  for (var y = 0; y < 3; y++) {
    for (var x = 0; x < 3; x++) {
      var total = 0.0;
      for (var k = 0; k < 3; k++) {
        total += left[y][k] * right[k][x];
      }
      result[y][x] = total;
    }
  }
  return result;
}

/// Processes matrix vector3 information in a JPEG XL codestream.
///
List<double> matrixVector3(List<List<double>> m, List<double> v) => [for (var y = 0; y < 3; y++) m[y][0] * v[0] + m[y][1] * v[1] + m[y][2] * v[2]];

/// Processes invert matrix3x3 information in a JPEG XL codestream.
///
List<List<double>>? invertMatrix3x3(List<List<double>> matrix) {
  var det = 0.0;
  for (var c = 0; c < 3; c++) {
    final int c1 = (c + 1) % 3;
    final int c2 = (c + 2) % 3;
    det += matrix[c][0] * matrix[c1][1] * matrix[c2][2] - matrix[c][0] * matrix[c1][2] * matrix[c2][1];
  }
  if (det == 0) {
    return null;
  }
  final double invDet = 1.0 / det;
  final List<List<double>> inverse = List.generate(3, (_) => List<double>.filled(3, 0));
  for (var x = 0; x < 3; x++) {
    for (var y = 0; y < 3; y++) {
      final int x1 = (x + 1) % 3;
      final int x2 = (x + 2) % 3;
      final int y1 = (y + 1) % 3;
      final int y2 = (y + 2) % 3;
      inverse[y][x] = (matrix[x1][y1] * matrix[x2][y2] - matrix[x2][y1] * matrix[x1][y2]) * invDet;
    }
  }
  return inverse;
}

/// Processes matrix identity3 information in a JPEG XL codestream.
///
List<List<double>> matrixIdentity3() => [
  [1, 0, 0],
  [0, 1, 0],
  [0, 0, 1],
];

/// Processes the get xyz data used by the JPEG XL codec.
///
List<double> _getXYZ(CieXy xy) {
  final double invY = 1.0 / xy.y;
  return [xy.x * invY, 1.0, (1.0 - xy.x - xy.y) * invY];
}

/// Processes the adapt white point data used by the JPEG XL codec.
///
List<List<double>> _adaptWhitePoint(CieXy? targetWP, CieXy? currentWP) {
  final CieXy target = targetWP ?? ColorFlags.getWhitePoint(ColorFlags.wpD50)!;
  final CieXy current = currentWP ?? ColorFlags.getWhitePoint(ColorFlags.wpD50)!;
  final List<double> lmsCurrent = matrixVector3(_bradford, _getXYZ(current));
  final List<double> lmsTarget = matrixVector3(_bradford, _getXYZ(target));
  final List<List<double>> a = List.generate(3, (_) => List<double>.filled(3, 0));
  for (var i = 0; i < 3; i++) {
    a[i][i] = lmsTarget[i] / lmsCurrent[i];
  }
  final List<List<double>> bradfordInverse = invertMatrix3x3(_bradford)!;
  return matrixMultiply3(matrixMultiply3(bradfordInverse, a), _bradford);
}

/// Processes the primaries to xyz data used by the JPEG XL codec.
///
List<List<double>> _primariesToXYZ(CiePrimaries primaries, CieXy? wp) {
  final CieXy whitePoint = wp ?? ColorFlags.getWhitePoint(ColorFlags.wpD50)!;
  final List<List<double>> primariesTr = [_getXYZ(primaries.red), _getXYZ(primaries.green), _getXYZ(primaries.blue)];
  // Transpose.
  final List<List<double>> primariesMatrix = List.generate(3, (y) => List<double>.generate(3, (x) => primariesTr[x][y]));
  final List<List<double>> inversePrimaries = invertMatrix3x3(primariesMatrix)!;
  final List<double> xyz = matrixVector3(inversePrimaries, _getXYZ(whitePoint));
  final List<List<double>> a = [
    [xyz[0], 0.0, 0.0],
    [0.0, xyz[1], 0.0],
    [0.0, 0.0, xyz[2]],
  ];
  return matrixMultiply3(primariesMatrix, a);
}

/// Conversion matrix from (currentPrim, currentWP) linear RGB to
/// (targetPrim, targetWP) linear RGB.
List<List<double>> getConversionMatrix(CiePrimaries targetPrim, CieXy targetWP, CiePrimaries currentPrim, CieXy currentWP) {
  if (targetPrim.matches(currentPrim) && targetWP.matches(currentWP)) {
    return matrixIdentity3();
  }
  List<List<double>>? whitePointConv;
  if (!targetWP.matches(currentWP)) {
    whitePointConv = _adaptWhitePoint(targetWP, currentWP);
  }
  final List<List<double>> forward = _primariesToXYZ(currentPrim, currentWP);
  final List<List<double>> reverse = invertMatrix3x3(_primariesToXYZ(targetPrim, targetWP))!;
  var result = forward;
  if (whitePointConv != null) {
    result = matrixMultiply3(whitePointConv, result);
  }
  return matrixMultiply3(reverse, result);
}
