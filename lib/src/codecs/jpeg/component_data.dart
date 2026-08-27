part of '../jpeg.dart';

/// Holds one decoded JPEG component expanded to full image resolution.
///
/// Components sampled at exactly half resolution are expanded with the
/// triangle filter used by reference decoders, which avoids the blockiness of
/// plain sample replication. Other sampling ratios fall back to replication.
final class _JpegComponentData {
  /// Full-resolution samples in row-major order.
  final Uint8List plane;

  /// Number of samples in one row of [plane].
  final int width;

  /// Expands [lines] from component resolution to [width] by [height].
  factory _JpegComponentData({
    required int horizontalSamples,
    required int maximumHorizontalSamples,
    required int verticalSamples,
    required int maximumVerticalSamples,
    required List<Uint8List> lines,
    required int width,
    required int height,
  }) {
    if (lines.isEmpty) {
      throw const ImageCodecException('A JPEG component contains no samples');
    }
    final int sampleWidth = _minimum(lines.first.length, (width * horizontalSamples + maximumHorizontalSamples - 1) ~/ maximumHorizontalSamples);
    final int sampleHeight = _minimum(lines.length, (height * verticalSamples + maximumVerticalSamples - 1) ~/ maximumVerticalSamples);
    if (sampleWidth < 1 || sampleHeight < 1) {
      throw const ImageCodecException('A JPEG component contains no samples');
    }
    final int horizontalRatio = maximumHorizontalSamples ~/ horizontalSamples;
    final int verticalRatio = maximumVerticalSamples ~/ verticalSamples;
    final bool exactRatios = horizontalRatio * horizontalSamples == maximumHorizontalSamples && verticalRatio * verticalSamples == maximumVerticalSamples;

    final Uint8List plane = Uint8List(width * height);
    if (exactRatios && horizontalRatio == 1 && verticalRatio == 1) {
      _copyPlane(lines, plane, width, height, sampleWidth, sampleHeight);
    } else if (exactRatios && horizontalRatio == 2 && verticalRatio == 1) {
      _upsampleHorizontally(lines, plane, width, height, sampleWidth, sampleHeight);
    } else if (exactRatios && horizontalRatio == 2 && verticalRatio == 2) {
      _upsampleBoth(lines, plane, width, height, sampleWidth, sampleHeight);
    } else {
      _replicate(lines, plane, width, height, sampleWidth, sampleHeight, horizontalSamples, maximumHorizontalSamples, verticalSamples, maximumVerticalSamples);
    }
    return _JpegComponentData._(plane: plane, width: width);
  }

  /// Creates component data around an expanded sample plane.
  const _JpegComponentData._({
    required this.plane,
    required this.width,
  });

  /// Copies a component that already covers every output sample.
  static void _copyPlane(List<Uint8List> lines, Uint8List plane, int width, int height, int sampleWidth, int sampleHeight) {
    final int copyWidth = _minimum(width, sampleWidth);
    for (int y = 0; y < height; y++) {
      final Uint8List line = lines[y < sampleHeight ? y : sampleHeight - 1];
      final int destination = y * width;
      plane.setRange(destination, destination + copyWidth, line);
      for (int x = copyWidth; x < width; x++) {
        plane[destination + x] = line[copyWidth - 1];
      }
    }
  }

  /// Doubles a component horizontally using the triangle filter.
  static void _upsampleHorizontally(List<Uint8List> lines, Uint8List plane, int width, int height, int sampleWidth, int sampleHeight) {
    for (int y = 0; y < height; y++) {
      _expandRow(lines[y < sampleHeight ? y : sampleHeight - 1], plane, y * width, width, sampleWidth);
    }
  }

  /// Doubles a component in both directions using the triangle filter.
  static void _upsampleBoth(List<Uint8List> lines, Uint8List plane, int width, int height, int sampleWidth, int sampleHeight) {
    final Int32List columnSums = Int32List(sampleWidth);
    for (int y = 0; y < height; y++) {
      final int sampleY = _minimum(y >> 1, sampleHeight - 1);
      // The nearer source row contributes three quarters of each output row.
      final int neighbourY = y.isEven ? (sampleY > 0 ? sampleY - 1 : 0) : _minimum(sampleY + 1, sampleHeight - 1);
      final Uint8List nearRow = lines[sampleY];
      final Uint8List farRow = lines[neighbourY];
      for (int x = 0; x < sampleWidth; x++) {
        columnSums[x] = nearRow[x] * 3 + farRow[x];
      }
      _expandColumnSums(columnSums, plane, y * width, width, sampleWidth);
    }
  }

  /// Repeats samples for ratios the triangle filter does not cover.
  static void _replicate(
    List<Uint8List> lines,
    Uint8List plane,
    int width,
    int height,
    int sampleWidth,
    int sampleHeight,
    int horizontalSamples,
    int maximumHorizontalSamples,
    int verticalSamples,
    int maximumVerticalSamples,
  ) {
    final Uint16List columns = Uint16List(width);
    for (int x = 0; x < width; x++) {
      final int sample = x * horizontalSamples ~/ maximumHorizontalSamples;
      columns[x] = sample < sampleWidth ? sample : sampleWidth - 1;
    }
    for (int y = 0; y < height; y++) {
      final int sample = y * verticalSamples ~/ maximumVerticalSamples;
      final Uint8List line = lines[sample < sampleHeight ? sample : sampleHeight - 1];
      final int destination = y * width;
      for (int x = 0; x < width; x++) {
        plane[destination + x] = line[columns[x]];
      }
    }
  }

  /// Writes one row expanded two-to-one from [row].
  static void _expandRow(Uint8List row, Uint8List plane, int destination, int width, int sampleWidth) {
    if (sampleWidth == 1) {
      plane.fillRange(destination, destination + width, row[0]);
      return;
    }
    int output = destination;
    final int limit = destination + width;
    if (output < limit) {
      plane[output++] = row[0];
    }
    if (output < limit) {
      plane[output++] = (row[0] * 3 + row[1] + 2) >> 2;
    }
    for (int x = 1; x < sampleWidth - 1 && output < limit; x++) {
      final int scaled = row[x] * 3;
      plane[output++] = (scaled + row[x - 1] + 1) >> 2;
      if (output < limit) {
        plane[output++] = (scaled + row[x + 1] + 2) >> 2;
      }
    }
    if (output < limit) {
      plane[output++] = (row[sampleWidth - 1] * 3 + row[sampleWidth - 2] + 1) >> 2;
    }
    if (output < limit) {
      plane[output++] = row[sampleWidth - 1];
    }
    while (output < limit) {
      plane[output] = plane[output - 1];
      output++;
    }
  }

  /// Writes one row expanded two-to-one from vertically weighted sums.
  static void _expandColumnSums(Int32List sums, Uint8List plane, int destination, int width, int sampleWidth) {
    if (sampleWidth == 1) {
      plane.fillRange(destination, destination + width, (sums[0] * 4 + 8) >> 4);
      return;
    }
    int output = destination;
    final int limit = destination + width;
    if (output < limit) {
      plane[output++] = (sums[0] * 4 + 8) >> 4;
    }
    if (output < limit) {
      plane[output++] = (sums[0] * 3 + sums[1] + 7) >> 4;
    }
    for (int x = 1; x < sampleWidth - 1 && output < limit; x++) {
      final int scaled = sums[x] * 3;
      plane[output++] = (scaled + sums[x - 1] + 8) >> 4;
      if (output < limit) {
        plane[output++] = (scaled + sums[x + 1] + 7) >> 4;
      }
    }
    if (output < limit) {
      plane[output++] = (sums[sampleWidth - 1] * 3 + sums[sampleWidth - 2] + 8) >> 4;
    }
    if (output < limit) {
      plane[output++] = (sums[sampleWidth - 1] * 4 + 7) >> 4;
    }
    while (output < limit) {
      plane[output] = plane[output - 1];
      output++;
    }
  }

  /// Returns the smaller integer.
  static int _minimum(int first, int second) => first < second ? first : second;
}
