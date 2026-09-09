part of 'image_format.dart';

/// Truevision TGA structural format.
final class _TgaFormat extends ImageFormat {
  /// Creates a Truevision TGA structural format.
  const _TgaFormat() : super(name: 'tga');

  @override
  bool matches(Uint8List bytes) => _hasTgaFooter(bytes) || _looksLikeHeaderlessTga(bytes);

  /// Recognizes the TGA 2.0 footer signature.
  bool _hasTgaFooter(Uint8List bytes) {
    const List<int> signature = [
      0x54,
      0x52,
      0x55,
      0x45,
      0x56,
      0x49,
      0x53,
      0x49,
      0x4f,
      0x4e,
      0x2d,
      0x58,
      0x46,
      0x49,
      0x4c,
      0x45,
      0x2e,
      0x00,
    ];
    if (bytes.length < 26) {
      return false;
    }
    final int offset = bytes.length - signature.length;
    for (int index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  /// Applies conservative structural checks to older TGA files without a footer.
  bool _looksLikeHeaderlessTga(Uint8List bytes) {
    if (bytes.length < 18) {
      return false;
    }
    final int colorMapType = bytes[1];
    final int imageType = bytes[2];
    final bool colorMapped = imageType == 1 || imageType == 9;
    final bool trueColor = imageType == 2 || imageType == 10;
    final bool grayscale = imageType == 3 || imageType == 11;
    if ((!colorMapped && !trueColor && !grayscale) || colorMapType != (colorMapped ? 1 : 0)) {
      return false;
    }
    final int width = bytes[12] | (bytes[13] << 8);
    final int height = bytes[14] | (bytes[15] << 8);
    final int depth = bytes[16];
    if (width == 0 || height == 0 || ![8, 15, 16, 24, 32].contains(depth)) {
      return false;
    }
    final int colorMapLength = bytes[5] | (bytes[6] << 8);
    final int colorMapDepth = bytes[7];
    final int paletteBytes = colorMapped ? colorMapLength * ((colorMapDepth + 7) ~/ 8) : 0;
    final int dataOffset = 18 + bytes[0] + paletteBytes;
    if (dataOffset >= bytes.length) {
      return false;
    }
    if (imageType <= 3) {
      final int pixelBytes = width * height * ((depth + 7) ~/ 8);
      return pixelBytes <= bytes.length - dataOffset;
    }
    return true;
  }
}
