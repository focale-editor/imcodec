part of '../../webp.dart';

/// Implements VP8's forward and inverse integer transforms.
abstract final class _Vp8EncoderTransform {
  /// First inverse-transform fixed-point multiplier.
  static const int _inverseCoefficient1 = 20091 + (1 << 16);

  /// Second inverse-transform fixed-point multiplier.
  static const int _inverseCoefficient2 = 35468;

  /// Transforms one four-by-four residual block into natural coefficient order.
  static Int32List forward(
    Uint8List source, {
    required int sourceOffset,
    required int sourceStride,
    required Uint8List prediction,
    required int predictionOffset,
    required int predictionStride,
  }) {
    final Int32List intermediate = Int32List(16);
    final Int32List output = Int32List(16);
    for (int row = 0; row < 4; ++row) {
      final int sourceRow = sourceOffset + row * sourceStride;
      final int predictionRow = predictionOffset + row * predictionStride;
      final int difference0 = source[sourceRow] - prediction[predictionRow];
      final int difference1 = source[sourceRow + 1] - prediction[predictionRow + 1];
      final int difference2 = source[sourceRow + 2] - prediction[predictionRow + 2];
      final int difference3 = source[sourceRow + 3] - prediction[predictionRow + 3];
      final int sumOutside = difference0 + difference3;
      final int sumInside = difference1 + difference2;
      final int differenceInside = difference1 - difference2;
      final int differenceOutside = difference0 - difference3;
      final int index = row * 4;
      intermediate[index] = (sumOutside + sumInside) * 8;
      intermediate[index + 1] = (differenceInside * 2217 + differenceOutside * 5352 + 1812) >> 9;
      intermediate[index + 2] = (sumOutside - sumInside) * 8;
      intermediate[index + 3] = (differenceOutside * 2217 - differenceInside * 5352 + 937) >> 9;
    }

    for (int column = 0; column < 4; ++column) {
      final int sumOutside = intermediate[column] + intermediate[12 + column];
      final int sumInside = intermediate[4 + column] + intermediate[8 + column];
      final int differenceInside = intermediate[4 + column] - intermediate[8 + column];
      final int differenceOutside = intermediate[column] - intermediate[12 + column];
      output[column] = (sumOutside + sumInside + 7) >> 4;
      output[4 + column] = ((differenceInside * 2217 + differenceOutside * 5352 + 12000) >> 16) + (differenceOutside != 0 ? 1 : 0);
      output[8 + column] = (sumOutside - sumInside + 7) >> 4;
      output[12 + column] = (differenceOutside * 2217 - differenceInside * 5352 + 51000) >> 16;
    }
    return output;
  }

  /// Applies one dequantized inverse transform to [destination].
  static void inverse(
    Int32List coefficients,
    Uint8List destination, {
    required int destinationOffset,
    required int destinationStride,
  }) {
    final Int32List intermediate = Int32List(16);
    int intermediateIndex = 0;
    for (int column = 0; column < 4; ++column) {
      final int sum = coefficients[column] + coefficients[8 + column];
      final int difference = coefficients[column] - coefficients[8 + column];
      final int rotatedDifference = _multiply(coefficients[4 + column], _inverseCoefficient2) - _multiply(coefficients[12 + column], _inverseCoefficient1);
      final int rotatedSum = _multiply(coefficients[4 + column], _inverseCoefficient1) + _multiply(coefficients[12 + column], _inverseCoefficient2);
      intermediate[intermediateIndex++] = sum + rotatedSum;
      intermediate[intermediateIndex++] = difference + rotatedDifference;
      intermediate[intermediateIndex++] = difference - rotatedDifference;
      intermediate[intermediateIndex++] = sum - rotatedSum;
    }

    for (int row = 0; row < 4; ++row) {
      final int directCurrent = intermediate[row] + 4;
      final int sum = directCurrent + intermediate[8 + row];
      final int difference = directCurrent - intermediate[8 + row];
      final int rotatedDifference = _multiply(intermediate[4 + row], _inverseCoefficient2) - _multiply(intermediate[12 + row], _inverseCoefficient1);
      final int rotatedSum = _multiply(intermediate[4 + row], _inverseCoefficient1) + _multiply(intermediate[12 + row], _inverseCoefficient2);
      final int output = destinationOffset + row * destinationStride;
      destination[output] = _clampByte(destination[output] + ((sum + rotatedSum) >> 3));
      destination[output + 1] = _clampByte(
        destination[output + 1] + ((difference + rotatedDifference) >> 3),
      );
      destination[output + 2] = _clampByte(
        destination[output + 2] + ((difference - rotatedDifference) >> 3),
      );
      destination[output + 3] = _clampByte(destination[output + 3] + ((sum - rotatedSum) >> 3));
    }
  }

  /// Applies the forward Walsh-Hadamard transform to sixteen luma DC values.
  static Int32List forwardWalshHadamard(Int32List directCurrent) {
    final Int32List intermediate = Int32List(16);
    final Int32List output = Int32List(16);
    for (int row = 0; row < 4; ++row) {
      final int index = row * 4;
      final int sumOutside = directCurrent[index] + directCurrent[index + 2];
      final int sumInside = directCurrent[index + 1] + directCurrent[index + 3];
      final int differenceInside = directCurrent[index + 1] - directCurrent[index + 3];
      final int differenceOutside = directCurrent[index] - directCurrent[index + 2];
      intermediate[index] = sumOutside + sumInside;
      intermediate[index + 1] = differenceOutside + differenceInside;
      intermediate[index + 2] = differenceOutside - differenceInside;
      intermediate[index + 3] = sumOutside - sumInside;
    }
    for (int column = 0; column < 4; ++column) {
      final int sumOutside = intermediate[column] + intermediate[8 + column];
      final int sumInside = intermediate[4 + column] + intermediate[12 + column];
      final int differenceInside = intermediate[4 + column] - intermediate[12 + column];
      final int differenceOutside = intermediate[column] - intermediate[8 + column];
      output[column] = (sumOutside + sumInside) >> 1;
      output[4 + column] = (differenceOutside + differenceInside) >> 1;
      output[8 + column] = (differenceOutside - differenceInside) >> 1;
      output[12 + column] = (sumOutside - sumInside) >> 1;
    }
    return output;
  }

  /// Reconstructs the per-block DC coefficients from a secondary luma block.
  static Int32List inverseWalshHadamard(Int32List coefficients) {
    final Int32List intermediate = Int32List(16);
    final Int32List output = Int32List(16);
    for (int column = 0; column < 4; ++column) {
      final int sumOutside = coefficients[column] + coefficients[12 + column];
      final int sumInside = coefficients[4 + column] + coefficients[8 + column];
      final int differenceInside = coefficients[4 + column] - coefficients[8 + column];
      final int differenceOutside = coefficients[column] - coefficients[12 + column];
      intermediate[column] = sumOutside + sumInside;
      intermediate[8 + column] = sumOutside - sumInside;
      intermediate[4 + column] = differenceOutside + differenceInside;
      intermediate[12 + column] = differenceOutside - differenceInside;
    }
    for (int row = 0; row < 4; ++row) {
      final int index = row * 4;
      final int directCurrent = intermediate[index] + 3;
      final int sumOutside = directCurrent + intermediate[index + 3];
      final int sumInside = intermediate[index + 1] + intermediate[index + 2];
      final int differenceInside = intermediate[index + 1] - intermediate[index + 2];
      final int differenceOutside = directCurrent - intermediate[index + 3];
      output[index] = (sumOutside + sumInside) >> 3;
      output[index + 1] = (differenceOutside + differenceInside) >> 3;
      output[index + 2] = (sumOutside - sumInside) >> 3;
      output[index + 3] = (differenceOutside - differenceInside) >> 3;
    }
    return output;
  }

  /// Multiplies fixed-point transform values with signed rounding semantics.
  static int _multiply(int first, int second) => (first * second) >> 16;

  /// Clamps [value] to one unsigned sample.
  static int _clampByte(int value) => value < 0
      ? 0
      : value > 255
      ? 255
      : value;
}
