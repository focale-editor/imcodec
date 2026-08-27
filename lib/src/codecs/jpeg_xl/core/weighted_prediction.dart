import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';

/// Fixed-point reciprocals used to normalize weighted predictions.
final Int32List weightedPredictionReciprocalTable = Int32List.fromList([
  for (int divisor = 1; divisor <= 64; divisor++) (1 << 24) ~/ divisor,
]);

/// Clamps [value] to the range spanned by three neighboring samples.
@pragma('vm:prefer-inline')
int clampWeightedPrediction({
  required int value,
  required int west,
  required int north,
  required int northEast,
}) {
  int lower = west < north ? west : north;
  int upper = west < north ? north : west;
  lower = lower < northEast ? lower : northEast;
  upper = upper > northEast ? upper : northEast;
  return value < lower
      ? lower
      : value > upper
      ? upper
      : value;
}

/// Whether predictor gradients permit clamping to neighboring samples.
@pragma('vm:prefer-inline')
bool shouldClampWeightedPrediction({
  required int northError,
  required int westError,
  required int northWestError,
}) => (northError < 0) != (westError < 0) || (northError < 0) != (northWestError < 0) || (northError == westError && northError == northWestError);

/// Computes one self-correcting predictor weight from its error plane.
@pragma('vm:prefer-inline')
int weightedPredictorPlaneWeight({
  required Int32List predictionErrors,
  required int offset,
  required int column,
  required int row,
  required int width,
  required int predictorWeight,
}) {
  final int northError = row > 0 ? predictionErrors[offset - width] : 0;
  final int westError = column > 0 ? predictionErrors[offset - 1] : 0;
  final int northWestError = column > 0 && row > 0 ? predictionErrors[offset - width - 1] : northError;
  final int westWestError = column > 1 ? predictionErrors[offset - 2] : 0;
  final int northEastError = column + 1 < width && row > 0 ? predictionErrors[offset - width + 1] : northError;
  int errorSum = northError + westError + northWestError + westWestError + northEastError;
  if (column + 1 == width) {
    errorSum += westError;
  }
  errorSum &= 0xffffffff;
  int shift = floorLog1p(errorSum) - 5;
  if (shift < 0) {
    shift = 0;
  }
  return 4 + ((predictorWeight * weightedPredictionReciprocalTable[errorSum >> shift]) >> shift);
}
