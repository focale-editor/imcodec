import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';

/// Applies the EXIF-style [orientation] (1-8) to a plane, returning a new
/// buffer (or the input for orientation 1).
ImageBuffer transposeBuffer(ImageBuffer src, int orientation) {
  if (orientation == 1 || src.height == 0 || src.width == 0) {
    return src;
  }
  final int h = src.height;
  final int w = src.width;
  final bool transposed = orientation > 4;
  final dh = transposed ? w : h;
  final dw = transposed ? h : w;
  final dest = src.isInt ? ImageBuffer.int32(height: dh, width: dw) : ImageBuffer.float32(height: dh, width: dw);

  // (destY, destX) for source (y, x).
  (int, int) map(int y, int x) => switch (orientation) {
    2 => (y, w - 1 - x), // flip horizontal
    3 => (h - 1 - y, w - 1 - x), // rotate 180
    4 => (h - 1 - y, x), // flip vertical
    5 => (x, y), // transpose
    6 => (x, h - 1 - y), // rotate clockwise
    7 => (w - 1 - x, h - 1 - y), // anti-transpose
    8 => (w - 1 - x, y), // rotate counterclockwise
    _ => throw ArgumentError('orientation \$orientation'),
  };

  if (src.isInt) {
    final List<Int32List> s = src.intRows;
    final List<Int32List> d = dest.intRows;
    for (var y = 0; y < h; y++) {
      final Int32List row = s[y];
      for (var x = 0; x < w; x++) {
        final (int dy, int dx) = map(y, x);
        d[dy][dx] = row[x];
      }
    }
  } else {
    final List<Float32List> s = src.floatRows;
    final List<Float32List> d = dest.floatRows;
    for (var y = 0; y < h; y++) {
      final Float32List row = s[y];
      for (var x = 0; x < w; x++) {
        final (int dy, int dx) = map(y, x);
        d[dy][dx] = row[x];
      }
    }
  }
  return dest;
}

/// Copies a rectangular region between two int planes.
void copyIntRegion(ImageBuffer src, int srcY, int srcX, ImageBuffer dest, int destY, int destX, int height, int width) {
  final List<Int32List> s = src.intRows;
  final List<Int32List> d = dest.intRows;
  for (var y = 0; y < height; y++) {
    d[y + destY].setRange(destX, destX + width, s[y + srcY], srcX);
  }
}

/// Copies a rectangular region between two float planes.
void copyFloatRegion(ImageBuffer src, int srcY, int srcX, ImageBuffer dest, int destY, int destX, int height, int width) {
  final List<Float32List> s = src.floatRows;
  final List<Float32List> d = dest.floatRows;
  for (var y = 0; y < height; y++) {
    d[y + destY].setRange(destX, destX + width, s[y + srcY], srcX);
  }
}
