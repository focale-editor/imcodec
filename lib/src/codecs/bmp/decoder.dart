part of '../bmp.dart';

/// Decodes uncompressed and bitfield BMP images to RGBA pixels.
final class BmpDecoder extends RasterDecoder {
  /// Creates a BMP decoder.
  const BmpDecoder();

  /// Decodes palette, 16-bit, 24-bit, or 32-bit BMP data.
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    final InputBuffer input = InputBuffer(bytes);
    if (input.readUint8() != 0x42 || input.readUint8() != 0x4d) {
      throw const ImageCodecException('Invalid BMP signature');
    }
    input.skip(8);
    final int pixelOffset = input.readUint32();
    final int dibOffset = input.position;
    final int dibSize = input.readUint32();
    if (dibSize != 12 && dibSize < 40) {
      throw ImageCodecException('Unsupported BMP information header size: $dibSize');
    }
    input.ensure(dibSize - 4);

    final bool coreHeader = dibSize == 12;
    final int width = coreHeader ? input.readUint16() : input.readInt32();
    final int encodedHeight = coreHeader ? input.readUint16() : input.readInt32();
    if (width < 1 || encodedHeight == 0) {
      throw const ImageCodecException('BMP dimensions must be positive and non-zero');
    }
    final bool topDown = encodedHeight < 0;
    final int height = encodedHeight.abs();
    _checkPixelLimit(width, height, maxPixels);
    if (input.readUint16() != 1) {
      throw const ImageCodecException('BMP must contain exactly one color plane');
    }
    final int bitsPerPixel = input.readUint16();
    if (![1, 4, 8, 16, 24, 32].contains(bitsPerPixel)) {
      throw ImageCodecException('Unsupported BMP bit depth: $bitsPerPixel');
    }

    final int compression = coreHeader ? 0 : input.readUint32();
    if (compression != 0 && compression != 3 && compression != 6) {
      throw ImageCodecException('Unsupported BMP compression method: $compression');
    }
    if ((compression == 3 || compression == 6) && bitsPerPixel != 16 && bitsPerPixel != 32) {
      throw const ImageCodecException('BMP bitfields require 16-bit or 32-bit pixels');
    }

    int colorsUsed = 0;
    if (!coreHeader) {
      input.skip(12);
      colorsUsed = input.readUint32();
      input.skip(4);
    }

    int redMask = bitsPerPixel == 16 ? 0x7c00 : 0x00ff0000;
    int greenMask = bitsPerPixel == 16 ? 0x03e0 : 0x0000ff00;
    int blueMask = bitsPerPixel == 16 ? 0x001f : 0x000000ff;
    int alphaMask = 0;
    if (compression == 3 || compression == 6) {
      final int masksOffset = dibSize >= 52 ? dibOffset + 40 : dibOffset + dibSize;
      final InputBuffer masks = InputBuffer(bytes)..seek(masksOffset);
      redMask = masks.readUint32();
      greenMask = masks.readUint32();
      blueMask = masks.readUint32();
      if (dibSize >= 56 || compression == 6) {
        alphaMask = masks.readUint32();
      }
    }

    int metadataEnd = dibOffset + dibSize;
    if ((compression == 3 || compression == 6) && dibSize < 52) {
      metadataEnd += compression == 6 ? 16 : 12;
    } else if (compression == 6 && dibSize < 56) {
      metadataEnd += 4;
    }
    final List<_Rgba> palette = [];
    if (bitsPerPixel <= 8) {
      final int paletteLength = colorsUsed == 0 ? 1 << bitsPerPixel : colorsUsed;
      if (paletteLength > 1 << bitsPerPixel) {
        throw const ImageCodecException('BMP palette contains more entries than its bit depth can address');
      }
      final int paletteOffset = dibOffset + dibSize;
      final int entryLength = coreHeader ? 3 : 4;
      metadataEnd = paletteOffset + paletteLength * entryLength;
      final InputBuffer paletteInput = InputBuffer(bytes)..seek(paletteOffset);
      for (int index = 0; index < paletteLength; index++) {
        final int blue = paletteInput.readUint8();
        final int green = paletteInput.readUint8();
        final int red = paletteInput.readUint8();
        if (entryLength == 4) {
          paletteInput.skip(1);
        }
        palette.add(_Rgba(red: red, green: green, blue: blue, alpha: 255));
      }
    }

    final int rowLength = ((width * bitsPerPixel + 31) ~/ 32) * 4;
    if (pixelOffset < metadataEnd || rowLength * height > bytes.length - pixelOffset) {
      throw const ImageCodecException('The BMP pixel data is truncated');
    }
    final Uint8List rgba = Uint8List(width * height * 4);
    bool hasNonZeroReservedAlpha = false;
    for (int sourceY = 0; sourceY < height; sourceY++) {
      final int destinationY = topDown ? sourceY : height - 1 - sourceY;
      final int rowOffset = pixelOffset + sourceY * rowLength;
      for (int x = 0; x < width; x++) {
        final _Rgba color = _readPixel(
          bytes,
          rowOffset,
          x,
          bitsPerPixel,
          palette,
          redMask,
          greenMask,
          blueMask,
          alphaMask,
        );
        final int destination = (destinationY * width + x) * 4;
        rgba[destination] = color.red;
        rgba[destination + 1] = color.green;
        rgba[destination + 2] = color.blue;
        rgba[destination + 3] = color.alpha;
        hasNonZeroReservedAlpha = hasNonZeroReservedAlpha || color.alpha != 0;
      }
    }

    if (bitsPerPixel == 32 && compression == 0 && !hasNonZeroReservedAlpha) {
      for (int offset = 3; offset < rgba.length; offset += 4) {
        rgba[offset] = 255;
      }
    }
    return Image.fromRgba(width: width, height: height, bytes: rgba, copy: false);
  }

  /// Reads one pixel from a BMP scanline.
  _Rgba _readPixel(
    Uint8List bytes,
    int rowOffset,
    int x,
    int bitsPerPixel,
    List<_Rgba> palette,
    int redMask,
    int greenMask,
    int blueMask,
    int alphaMask,
  ) {
    if (bitsPerPixel <= 8) {
      final int index = switch (bitsPerPixel) {
        1 => (bytes[rowOffset + (x >> 3)] >> (7 - (x & 7))) & 1,
        4 => (bytes[rowOffset + (x >> 1)] >> (x.isEven ? 4 : 0)) & 0x0f,
        8 => bytes[rowOffset + x],
        _ => throw StateError('Unexpected indexed BMP depth'),
      };
      if (index >= palette.length) {
        throw const ImageCodecException('BMP pixel references a missing palette entry');
      }
      return palette[index];
    }
    if (bitsPerPixel == 24) {
      final int offset = rowOffset + x * 3;
      return _Rgba(
        red: bytes[offset + 2],
        green: bytes[offset + 1],
        blue: bytes[offset],
        alpha: 255,
      );
    }

    final int byteLength = bitsPerPixel ~/ 8;
    final int offset = rowOffset + x * byteLength;
    int value = 0;
    for (int byte = 0; byte < byteLength; byte++) {
      value |= bytes[offset + byte] << (byte * 8);
    }
    final int alpha = alphaMask == 0 ? (bitsPerPixel == 32 ? bytes[offset + 3] : 255) : _scaleMask(value, alphaMask);
    return _Rgba(
      red: _scaleMask(value, redMask),
      green: _scaleMask(value, greenMask),
      blue: _scaleMask(value, blueMask),
      alpha: alpha,
    );
  }

  /// Scales one packed bitfield channel to eight bits.
  int _scaleMask(int value, int mask) {
    if (mask == 0) {
      return 0;
    }
    int shift = 0;
    int shiftedMask = mask;
    while (shiftedMask.isEven) {
      shiftedMask >>>= 1;
      shift++;
    }
    return (((value & mask) >>> shift) * 255 + (shiftedMask >> 1)) ~/ shiftedMask;
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

/// Holds one decoded color without exposing an additional public image type.
final class _Rgba {
  /// Red channel.
  final int red;

  /// Green channel.
  final int green;

  /// Blue channel.
  final int blue;

  /// Alpha channel.
  final int alpha;

  /// Creates a color from eight-bit channels.
  const _Rgba({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
  });
}
