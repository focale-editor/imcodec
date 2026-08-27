part of '../qoi.dart';

/// Decodes Quite OK Image data to RGBA pixels.
final class QoiDecoder extends RasterDecoder {
  /// Creates a QOI decoder.
  const QoiDecoder();

  /// Decodes one complete QOI image.
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    final InputBuffer input = InputBuffer(bytes);
    if (input.remaining < 14 || input.readUint8() != 0x71 || input.readUint8() != 0x6f || input.readUint8() != 0x69 || input.readUint8() != 0x66) {
      throw const ImageCodecException('Invalid QOI signature');
    }
    final int width = input.readUint32(endian: Endian.big);
    final int height = input.readUint32(endian: Endian.big);
    final int channels = input.readUint8();
    final int colorSpace = input.readUint8();
    if (width == 0 || height == 0) {
      throw const ImageCodecException('QOI dimensions must be non-zero');
    }
    if (channels != 3 && channels != 4) {
      throw ImageCodecException('Invalid QOI channel count: $channels');
    }
    if (colorSpace != 0 && colorSpace != 1) {
      throw ImageCodecException('Invalid QOI color space: $colorSpace');
    }
    _checkPixelLimit(width, height, maxPixels);

    final int pixelCount = width * height;
    final Uint8List rgba = Uint8List(pixelCount * 4);
    // Colors are packed into one integer so that neither the running index nor
    // the decoding loop allocates per pixel.
    final Int32List index = Int32List(64);
    int red = 0;
    int green = 0;
    int blue = 0;
    int alpha = 255;
    int pixel = 0;
    while (pixel < pixelCount) {
      final int opcode = input.readUint8();
      int run = 1;
      if (opcode == 0xfe) {
        red = input.readUint8();
        green = input.readUint8();
        blue = input.readUint8();
      } else if (opcode == 0xff) {
        red = input.readUint8();
        green = input.readUint8();
        blue = input.readUint8();
        alpha = input.readUint8();
      } else {
        switch (opcode & 0xc0) {
          case 0x00:
            final int packed = index[opcode & 0x3f];
            red = (packed >>> 24) & 0xff;
            green = (packed >>> 16) & 0xff;
            blue = (packed >>> 8) & 0xff;
            alpha = packed & 0xff;
          case 0x40:
            red = (red + ((opcode >>> 4) & 0x03) - 2) & 0xff;
            green = (green + ((opcode >>> 2) & 0x03) - 2) & 0xff;
            blue = (blue + (opcode & 0x03) - 2) & 0xff;
          case 0x80:
            final int second = input.readUint8();
            final int greenDifference = (opcode & 0x3f) - 32;
            red = (red + greenDifference + (second >>> 4) - 8) & 0xff;
            green = (green + greenDifference) & 0xff;
            blue = (blue + greenDifference + (second & 0x0f) - 8) & 0xff;
          case 0xc0:
            run = (opcode & 0x3f) + 1;
        }
      }
      if (run > pixelCount - pixel) {
        throw const ImageCodecException('A QOI run exceeds the declared image dimensions');
      }
      index[_hashPosition(red, green, blue, alpha)] = (red << 24) | (green << 16) | (blue << 8) | alpha;
      for (int count = 0; count < run; count++) {
        final int offset = pixel++ * 4;
        rgba[offset] = red;
        rgba[offset + 1] = green;
        rgba[offset + 2] = blue;
        rgba[offset + 3] = alpha;
      }
    }
    if (input.position != bytes.length - 8 || !_hasEndMarker(bytes)) {
      throw const ImageCodecException('QOI end marker is missing');
    }
    return Image.fromRgba(width: width, height: height, bytes: rgba, copy: false);
  }

  /// Returns the running-index slot specified by the QOI color hash.
  static int _hashPosition(int red, int green, int blue, int alpha) => (red * 3 + green * 5 + blue * 7 + alpha * 11) & 63;

  /// Checks the fixed eight-byte marker at the end of a QOI stream.
  bool _hasEndMarker(Uint8List bytes) {
    const List<int> marker = [0, 0, 0, 0, 0, 0, 0, 1];
    final int offset = bytes.length - marker.length;
    for (int index = 0; index < marker.length; index++) {
      if (bytes[offset + index] != marker[index]) {
        return false;
      }
    }
    return true;
  }

  /// Rejects invalid dimensions before allocating decoded pixels.
  void _checkPixelLimit(int width, int height, int maxPixels) {
    if (maxPixels < 1) {
      throw RangeError.range(maxPixels, 1, null, 'maxPixels');
    }
    final int pixelCount = width * height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
  }
}
