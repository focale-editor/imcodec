// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../jbig2.dart';

/// This class _Jbig2represents a bi-level image that is organized like a bitmap.
class _Jbig2Bitmap {
  /// The height of the bitmap in pixels.
  final int height;

  /// The width of the bitmap in pixels.
  final int width;

  /// The amount of bytes used per row.
  final int rowStride;

  /// 8 pixels per byte, 0 for white, 1 for black
  final Uint8List bitmap;

  /// Creates an instance of a blank image.
  /// The image data is stored in a byte array. Each pixels is stored as one bit, so that each byte
  /// contains 8 pixel. A pixel has by default the value 0 for white and 1 for black.
  /// Row stride means the amount of bytes per line. It is computed automatically and fills the pad
  /// bits with 0.
  ///
  /// [width] - The real width of the bitmap in pixels.
  /// [height] - The real height of the bitmap in pixels.
  _Jbig2Bitmap({
    required this.width,
    required this.height,
  }) : rowStride = (width + 7) >> 3,
       bitmap = _Jbig2Budget.allocate(width, height);

  /// Returns the value of a pixel specified by the given coordinates.
  ///
  /// By default, the value is 0 for a white pixel and 1 for a black pixel. The value
  /// is placed in the rightmost bit in the byte.
  ///
  /// [x] - The x coordinate of the pixel.
  /// [y] - The y coordinate of the pixel.
  /// Returns The value of a pixel.
  int getPixel(int x, int y) {
    final int byteIndex = getByteIndex(x, y);
    final int bitOffset = getBitOffset(x);

    final int toShift = 7 - bitOffset;
    return (getByte(byteIndex) >> toShift) & 0x01;
  }

  /// Updates pixel.
  void setPixel(int x, int y, int pixelValue) {
    final int byteIndex = getByteIndex(x, y);
    final int bitOffset = getBitOffset(x);

    final int shift = 7 - bitOffset;

    final int src = bitmap[byteIndex];
    final int result = (src | (pixelValue << shift));
    bitmap[byteIndex] = result;
  }

  /// Sets a pixel to [pixelValue], clearing it when the value is 0.
  ///
  /// [setPixel] can only ever turn a pixel black, which is all a decoding
  /// procedure needs. Composing regions with an operator whose identity
  /// element is 1, such as and, has to be able to turn a pixel white again.
  void writePixel(int x, int y, int pixelValue) {
    final int byteIndex = getByteIndex(x, y);
    final int shift = 7 - getBitOffset(x);
    final int mask = 1 << shift;
    if (pixelValue != 0) {
      bitmap[byteIndex] |= mask;
    } else {
      bitmap[byteIndex] &= (~mask) & 0xff;
    }
  }

  /// Returns the index of the byte that contains the pixel, specified by the pixel's x and y
  /// coordinates.
  ///
  /// [x] - The pixel's x coordinate.
  /// [y] - The pixel's y coordinate.
  /// Returns The index of the byte that contains the specified pixel.
  int getByteIndex(int x, int y) => y * rowStride + (x >> 3);

  /// Simply returns the byte array of this bitmap.
  ///
  /// Returns The byte array of this bitmap.
  Uint8List getByteArray() => bitmap;

  /// Simply returns a byte from the bitmap byte array. Throws an [RangeError]
  /// if the given index is out of bound.
  ///
  /// [index] - The array index that specifies the position of the wanted byte.
  /// Returns The byte at the [index]-position.
  int getByte(int index) => bitmap[index];

  /// Simply sets the given value at the given array index position. Throws an
  /// [RangeError] if the given index is out of bound.
  ///
  /// [index] - The array index that specifies the position of a byte.
  /// [value] - The byte that should be set.
  void setByte(int index, int value) {
    bitmap[index] = value;
  }

  /// Converts the byte at specified index into an integer and returns the value. Throws an
  /// [RangeError] if the given index is out of bound.
  ///
  /// [index] - The array index that specifies the position of the wanted byte.
  /// Returns The converted byte at the [index]-position as an integer.
  int getByteAsInteger(int index) => bitmap[index] & 0xff;

  /// Computes the offset of the given x coordinate in its byte. The method uses optimized modulo
  /// operation for a better performance.
  ///
  /// [x] - The x coordinate of a pixel.
  /// Returns The bit offset of a pixel in its byte.
  int getBitOffset(int x) => x & 7;

  /// Returns memory size.
  int getMemorySize() => bitmap.length;
}
