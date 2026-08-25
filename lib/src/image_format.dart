import 'dart:typed_data';

/// Image formats supported by this package.
enum ImageFormat {
  /// Windows bitmap image.
  bmp,

  /// Joint Photographic Experts Group image.
  jpeg,

  /// JPEG XL image.
  jpegXl,

  /// Portable Network Graphics image.
  png,

  /// Quite OK Image.
  qoi,

  /// Truevision TGA image.
  tga,

  /// Tagged Image File Format image.
  tiff,

  /// WebP image.
  webp;

  /// Detects a supported format from its file signature.
  static ImageFormat? sniff(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
      return ImageFormat.bmp;
    }
    if (bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47 && bytes[4] == 0x0d && bytes[5] == 0x0a && bytes[6] == 0x1a && bytes[7] == 0x0a) {
      return ImageFormat.png;
    }
    if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
      return ImageFormat.jpeg;
    }
    if ((bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0x0a) ||
        (bytes.length >= 12 &&
            bytes[0] == 0x00 &&
            bytes[1] == 0x00 &&
            bytes[2] == 0x00 &&
            bytes[3] == 0x0c &&
            bytes[4] == 0x4a &&
            bytes[5] == 0x58 &&
            bytes[6] == 0x4c &&
            bytes[7] == 0x20 &&
            bytes[8] == 0x0d &&
            bytes[9] == 0x0a &&
            bytes[10] == 0x87 &&
            bytes[11] == 0x0a)) {
      return ImageFormat.jpegXl;
    }
    if (bytes.length >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return ImageFormat.webp;
    }
    if (bytes.length >= 4 && bytes[0] == 0x71 && bytes[1] == 0x6f && bytes[2] == 0x69 && bytes[3] == 0x66) {
      return ImageFormat.qoi;
    }
    if (bytes.length >= 4 && ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2a && bytes[3] == 0x00) || (bytes[0] == 0x4d && bytes[1] == 0x4d && bytes[2] == 0x00 && bytes[3] == 0x2a))) {
      return ImageFormat.tiff;
    }
    if (_hasTgaFooter(bytes) || _looksLikeHeaderlessTga(bytes)) {
      return ImageFormat.tga;
    }
    return null;
  }

  /// Recognizes the TGA 2.0 footer signature.
  static bool _hasTgaFooter(Uint8List bytes) {
    const List<int> signature = [0x54, 0x52, 0x55, 0x45, 0x56, 0x49, 0x53, 0x49, 0x4f, 0x4e, 0x2d, 0x58, 0x46, 0x49, 0x4c, 0x45, 0x2e, 0x00];
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
  static bool _looksLikeHeaderlessTga(Uint8List bytes) {
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
