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
    final List<_QoiColor> index = List<_QoiColor>.filled(64, const _QoiColor(red: 0, green: 0, blue: 0, alpha: 0));
    _QoiColor color = const _QoiColor(red: 0, green: 0, blue: 0, alpha: 255);
    int pixel = 0;
    while (pixel < pixelCount) {
      final int opcode = input.readUint8();
      int run = 1;
      if (opcode == 0xfe) {
        color = _QoiColor(
          red: input.readUint8(),
          green: input.readUint8(),
          blue: input.readUint8(),
          alpha: color.alpha,
        );
      } else if (opcode == 0xff) {
        color = _QoiColor(
          red: input.readUint8(),
          green: input.readUint8(),
          blue: input.readUint8(),
          alpha: input.readUint8(),
        );
      } else {
        switch (opcode & 0xc0) {
          case 0x00:
            color = index[opcode & 0x3f];
          case 0x40:
            color = _QoiColor(
              red: (color.red + ((opcode >>> 4) & 0x03) - 2) & 0xff,
              green: (color.green + ((opcode >>> 2) & 0x03) - 2) & 0xff,
              blue: (color.blue + (opcode & 0x03) - 2) & 0xff,
              alpha: color.alpha,
            );
          case 0x80:
            final int second = input.readUint8();
            final int greenDifference = (opcode & 0x3f) - 32;
            color = _QoiColor(
              red: (color.red + greenDifference + (second >>> 4) - 8) & 0xff,
              green: (color.green + greenDifference) & 0xff,
              blue: (color.blue + greenDifference + (second & 0x0f) - 8) & 0xff,
              alpha: color.alpha,
            );
          case 0xc0:
            run = (opcode & 0x3f) + 1;
        }
      }
      if (run > pixelCount - pixel) {
        throw const ImageCodecException('A QOI run exceeds the declared image dimensions');
      }
      index[color.hashPosition] = color;
      for (int count = 0; count < run; count++) {
        final int offset = pixel++ * 4;
        rgba[offset] = color.red;
        rgba[offset + 1] = color.green;
        rgba[offset + 2] = color.blue;
        rgba[offset + 3] = color.alpha;
      }
    }
    if (input.position != bytes.length - 8 || !_hasEndMarker(bytes)) {
      throw const ImageCodecException('QOI end marker is missing');
    }
    return Image.fromRgba(width: width, height: height, bytes: rgba, copy: false);
  }

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

/// Holds one QOI pixel and its hash-table position.
final class _QoiColor {
  /// Red channel.
  final int red;

  /// Green channel.
  final int green;

  /// Blue channel.
  final int blue;

  /// Alpha channel.
  final int alpha;

  /// Creates a color from eight-bit channels.
  const _QoiColor({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
  });

  /// Index specified by the QOI color hash.
  int get hashPosition => (red * 3 + green * 5 + blue * 7 + alpha * 11) % 64;

  @override
  bool operator ==(Object other) => other is _QoiColor && red == other.red && green == other.green && blue == other.blue && alpha == other.alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);
}
