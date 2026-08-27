part of '../tga.dart';

/// Decodes color-mapped, true-color, and grayscale TGA images.
final class TgaDecoder extends RasterDecoder {
  /// Creates a TGA decoder.
  const TgaDecoder();

  /// Decodes uncompressed or run-length encoded TGA data.
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    final InputBuffer input = InputBuffer(bytes);
    input.ensure(18);
    final int identifierLength = input.readUint8();
    final int colorMapType = input.readUint8();
    final int imageType = input.readUint8();
    final int colorMapOrigin = input.readUint16();
    final int colorMapLength = input.readUint16();
    final int colorMapDepth = input.readUint8();
    input.skip(4);
    final int width = input.readUint16();
    final int height = input.readUint16();
    final int pixelDepth = input.readUint8();
    final int descriptor = input.readUint8();

    final bool colorMapped = imageType == 1 || imageType == 9;
    final bool trueColor = imageType == 2 || imageType == 10;
    final bool grayscale = imageType == 3 || imageType == 11;
    final bool runLengthEncoded = imageType >= 9;
    if (!colorMapped && !trueColor && !grayscale) {
      throw ImageCodecException('Unsupported TGA image type: $imageType');
    }
    if (colorMapType != (colorMapped ? 1 : 0)) {
      throw const ImageCodecException('TGA color-map metadata does not match its image type');
    }
    if (width == 0 || height == 0) {
      throw const ImageCodecException('TGA dimensions must be non-zero');
    }
    _checkPixelLimit(width, height, maxPixels);
    if ((descriptor & 0xc0) != 0) {
      throw const ImageCodecException('Interleaved TGA images are not supported');
    }
    if (colorMapped && pixelDepth != 8 && pixelDepth != 16) {
      throw ImageCodecException('Unsupported TGA palette index depth: $pixelDepth');
    }
    if (trueColor && ![15, 16, 24, 32].contains(pixelDepth)) {
      throw ImageCodecException('Unsupported TGA color depth: $pixelDepth');
    }
    if (grayscale && pixelDepth != 8 && pixelDepth != 16) {
      throw ImageCodecException('Unsupported TGA grayscale depth: $pixelDepth');
    }

    input.skip(identifierLength);
    Int32List colorMap = _emptyColorMap;
    if (colorMapped) {
      if (![15, 16, 24, 32].contains(colorMapDepth)) {
        throw ImageCodecException('Unsupported TGA color-map depth: $colorMapDepth');
      }
      colorMap = Int32List(colorMapLength);
      for (int index = 0; index < colorMapLength; index++) {
        colorMap[index] = _readDirectColor(input, colorMapDepth, hasAlphaBit: colorMapDepth == 16);
      }
    }

    final Uint8List rgba = Uint8List(width * height * 4);
    final bool tracksAlpha = pixelDepth == 32 || (colorMapped && colorMapDepth == 32) || (grayscale && pixelDepth == 16);
    int decodedPixels = 0;
    while (decodedPixels < width * height) {
      final int packetLength = runLengthEncoded ? (input.readUint8() & 0x7f) + 1 : 1;
      final bool repeatedPacket = runLengthEncoded && (bytes[input.position - 1] & 0x80) != 0;
      if (packetLength > width * height - decodedPixels) {
        throw const ImageCodecException('A TGA packet exceeds the declared image dimensions');
      }
      if (repeatedPacket) {
        final int color = _readColor(input, colorMapped, grayscale, pixelDepth, colorMapOrigin, colorMap, descriptor);
        for (int count = 0; count < packetLength; count++) {
          _storeColor(rgba, decodedPixels++, width, height, descriptor, color);
        }
      } else {
        for (int count = 0; count < packetLength; count++) {
          final int color = _readColor(input, colorMapped, grayscale, pixelDepth, colorMapOrigin, colorMap, descriptor);
          _storeColor(rgba, decodedPixels++, width, height, descriptor, color);
        }
      }
    }
    if (tracksAlpha && _isFullyTransparent(rgba)) {
      // Writers that never set the attribute bits leave every alpha byte at
      // zero. Such a file is opaque in practice, so honour that instead of
      // returning an invisible image.
      for (int offset = 3; offset < rgba.length; offset += 4) {
        rgba[offset] = 255;
      }
    }
    return Image.fromRgba(width: width, height: height, bytes: rgba, copy: false);
  }

  /// Reports whether every decoded pixel is fully transparent.
  bool _isFullyTransparent(Uint8List rgba) {
    for (int offset = 3; offset < rgba.length; offset += 4) {
      if (rgba[offset] != 0) {
        return false;
      }
    }
    return true;
  }

  /// Reads a direct, grayscale, or palette-indexed TGA color.
  /// Colors are packed into one integer so that decoding never allocates.
  int _readColor(
    InputBuffer input,
    bool colorMapped,
    bool grayscale,
    int pixelDepth,
    int colorMapOrigin,
    Int32List colorMap,
    int descriptor,
  ) {
    if (colorMapped) {
      final int index = (pixelDepth == 8 ? input.readUint8() : input.readUint16()) - colorMapOrigin;
      if (index < 0 || index >= colorMap.length) {
        throw const ImageCodecException('TGA pixel references a missing color-map entry');
      }
      return colorMap[index];
    }
    if (grayscale) {
      final int gray = input.readUint8();
      final int alpha = pixelDepth == 16 ? input.readUint8() : 255;
      return (gray << 24) | (gray << 16) | (gray << 8) | alpha;
    }
    return _readDirectColor(input, pixelDepth, hasAlphaBit: (descriptor & 0x0f) != 0);
  }

  /// Reads a packed or byte-aligned TGA true color.
  int _readDirectColor(InputBuffer input, int depth, {required bool hasAlphaBit}) {
    if (depth == 15 || depth == 16) {
      final int value = input.readUint16();
      final int red = ((value >>> 10) & 0x1f) * 255 ~/ 31;
      final int green = ((value >>> 5) & 0x1f) * 255 ~/ 31;
      final int blue = (value & 0x1f) * 255 ~/ 31;
      final int alpha = depth == 16 && hasAlphaBit ? ((value & 0x8000) == 0 ? 0 : 255) : 255;
      return (red << 24) | (green << 16) | (blue << 8) | alpha;
    }
    final int blue = input.readUint8();
    final int green = input.readUint8();
    final int red = input.readUint8();
    final int alpha = depth == 32 ? input.readUint8() : 255;
    return (red << 24) | (green << 16) | (blue << 8) | alpha;
  }

  /// Maps stream order and origin flags to the normalized top-left layout.
  void _storeColor(Uint8List rgba, int streamIndex, int width, int height, int descriptor, int color) {
    final int streamY = streamIndex ~/ width;
    final int streamX = streamIndex - streamY * width;
    final int x = (descriptor & 0x10) == 0 ? streamX : width - 1 - streamX;
    final int y = (descriptor & 0x20) != 0 ? streamY : height - 1 - streamY;
    final int offset = (y * width + x) * 4;
    rgba[offset] = (color >>> 24) & 0xff;
    rgba[offset + 1] = (color >>> 16) & 0xff;
    rgba[offset + 2] = (color >>> 8) & 0xff;
    rgba[offset + 3] = color & 0xff;
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

/// Shared empty color map for images without a palette.
final Int32List _emptyColorMap = Int32List(0);
