part of '../tga.dart';

/// Encodes RGBA pixels as 32-bit true-color TGA data.
final class TgaEncoder extends RasterEncoder {
  /// Whether encoding uses TGA run-length packets.
  final bool runLengthEncoding;

  /// TGA 2.0 footer signature.
  static const List<int> _footerSignature = [0x54, 0x52, 0x55, 0x45, 0x56, 0x49, 0x53, 0x49, 0x4f, 0x4e, 0x2d, 0x58, 0x46, 0x49, 0x4c, 0x45, 0x2e, 0x00];

  /// Creates a TGA encoder.
  const TgaEncoder({
    this.runLengthEncoding = true,
  });

  /// Encodes [image], optionally using TGA run-length encoding.
  @override
  Uint8List encode(Image image) {
    if (image.width > 65535 || image.height > 65535) {
      throw const ImageCodecException('TGA dimensions may not exceed 65535 pixels');
    }
    final OutputBuffer output = OutputBuffer()
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(runLengthEncoding ? 10 : 2)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeByte(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(image.width)
      ..writeUint16(image.height)
      ..writeByte(32)
      ..writeByte(0x28);
    if (runLengthEncoding) {
      _writeRunLengthPixels(output, image);
    } else {
      for (int pixel = 0; pixel < image.width * image.height; pixel++) {
        _writePixel(output, image.bytes, pixel);
      }
    }
    output
      ..writeBytes(Uint8List(8))
      ..writeBytes(_footerSignature);
    return Uint8List.fromList(output.getBytes());
  }

  /// Writes packets of repeated or raw pixels, each capped at 128 pixels.
  void _writeRunLengthPixels(OutputBuffer output, Image image) {
    final int pixelCount = image.width * image.height;
    int pixel = 0;
    while (pixel < pixelCount) {
      final int repeated = _runLength(image.bytes, pixel, pixelCount);
      if (repeated >= 2) {
        output.writeByte(0x80 | (repeated - 1));
        _writePixel(output, image.bytes, pixel);
        pixel += repeated;
        continue;
      }

      final int start = pixel;
      pixel++;
      while (pixel < pixelCount && pixel - start < 128 && _runLength(image.bytes, pixel, pixelCount) < 2) {
        pixel++;
      }
      output.writeByte(pixel - start - 1);
      for (int rawPixel = start; rawPixel < pixel; rawPixel++) {
        _writePixel(output, image.bytes, rawPixel);
      }
    }
  }

  /// Counts equal consecutive pixels up to the TGA packet limit.
  int _runLength(Uint8List bytes, int start, int pixelCount) {
    int length = 1;
    while (length < 128 && start + length < pixelCount && _pixelsEqual(bytes, start, start + length)) {
      length++;
    }
    return length;
  }

  /// Compares two RGBA pixels.
  bool _pixelsEqual(Uint8List bytes, int first, int second) {
    final int firstOffset = first * 4;
    final int secondOffset = second * 4;
    return bytes[firstOffset] == bytes[secondOffset] &&
        bytes[firstOffset + 1] == bytes[secondOffset + 1] &&
        bytes[firstOffset + 2] == bytes[secondOffset + 2] &&
        bytes[firstOffset + 3] == bytes[secondOffset + 3];
  }

  /// Writes one RGBA pixel in TGA's BGRA byte order.
  void _writePixel(OutputBuffer output, Uint8List bytes, int pixel) {
    final int offset = pixel * 4;
    output
      ..writeByte(bytes[offset + 2])
      ..writeByte(bytes[offset + 1])
      ..writeByte(bytes[offset])
      ..writeByte(bytes[offset + 3]);
  }
}
