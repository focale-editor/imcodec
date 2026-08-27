part of '../../webp.dart';

/// Reverses the predictive filters used by a WebP alpha plane.
final class _WebPAlphaFilters {
  /// Number of filter identifiers defined by the WebP alpha specification.
  static const int filterCount = 4;

  /// Filter functions indexed by their encoded identifier.
  static const List<void Function(int width, int height, int stride, int row, int rowCount, Uint8List data)?> unfilters = [
    null,
    _unfilterHorizontal,
    _unfilterVertical,
    _unfilterGradient,
  ];

  /// Prevents instantiation of this static utility class.
  const _WebPAlphaFilters._();

  /// Reconstructs rows predicted from the pixel immediately to their left.
  static void _unfilterHorizontal(int width, int height, int stride, int row, int rowCount, Uint8List data) {
    final int endRow = math.min(row + rowCount, height);
    for (int currentRow = row; currentRow < endRow; currentRow++) {
      final int rowOffset = currentRow * stride;
      if (currentRow > 0) {
        data[rowOffset] = (data[rowOffset] + data[rowOffset - stride]) & 0xff;
      }
      for (int x = 1; x < width; x++) {
        final int offset = rowOffset + x;
        data[offset] = (data[offset] + data[offset - 1]) & 0xff;
      }
    }
  }

  /// Reconstructs rows predicted from the corresponding pixel above them.
  static void _unfilterVertical(int width, int height, int stride, int row, int rowCount, Uint8List data) {
    final int endRow = math.min(row + rowCount, height);
    for (int currentRow = row; currentRow < endRow; currentRow++) {
      final int rowOffset = currentRow * stride;
      if (currentRow == 0) {
        for (int x = 1; x < width; x++) {
          final int offset = rowOffset + x;
          data[offset] = (data[offset] + data[offset - 1]) & 0xff;
        }
        continue;
      }
      for (int x = 0; x < width; x++) {
        final int offset = rowOffset + x;
        data[offset] = (data[offset] + data[offset - stride]) & 0xff;
      }
    }
  }

  /// Reconstructs rows predicted by a clamped two-dimensional gradient.
  static void _unfilterGradient(int width, int height, int stride, int row, int rowCount, Uint8List data) {
    final int endRow = math.min(row + rowCount, height);
    for (int currentRow = row; currentRow < endRow; currentRow++) {
      final int rowOffset = currentRow * stride;
      if (currentRow == 0) {
        for (int x = 1; x < width; x++) {
          final int offset = rowOffset + x;
          data[offset] = (data[offset] + data[offset - 1]) & 0xff;
        }
        continue;
      }
      data[rowOffset] = (data[rowOffset] + data[rowOffset - stride]) & 0xff;
      for (int x = 1; x < width; x++) {
        final int offset = rowOffset + x;
        final int prediction = _gradient(
          data[offset - 1],
          data[offset - stride],
          data[offset - stride - 1],
        );
        data[offset] = (data[offset] + prediction) & 0xff;
      }
    }
  }

  /// Clamps the gradient of [left], [above], and [upperLeft] to one byte.
  static int _gradient(int left, int above, int upperLeft) {
    final int value = left + above - upperLeft;
    return value < 0
        ? 0
        : value > 255
        ? 255
        : value;
  }
}
