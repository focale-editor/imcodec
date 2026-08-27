part of '../bmp.dart';

/// Decodes uncompressed, bitfield, and run-length encoded BMP images.
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
    if (compression != 0 && compression != 1 && compression != 2 && compression != 3 && compression != 6) {
      throw ImageCodecException('Unsupported BMP compression method: $compression');
    }
    if ((compression == 3 || compression == 6) && bitsPerPixel != 16 && bitsPerPixel != 32) {
      throw const ImageCodecException('BMP bitfields require 16-bit or 32-bit pixels');
    }
    if ((compression == 1 && bitsPerPixel != 8) || (compression == 2 && bitsPerPixel != 4)) {
      throw const ImageCodecException('BMP run-length compression does not match its bit depth');
    }
    if (compression != 0 && topDown) {
      throw const ImageCodecException('Compressed BMP images may not be stored top-down');
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
    Int32List? palette;
    if (bitsPerPixel <= 8) {
      final int paletteOffset = dibOffset + dibSize;
      final int entryLength = coreHeader ? 3 : 4;
      final int declaredLength = colorsUsed == 0 ? 1 << bitsPerPixel : colorsUsed;
      if (declaredLength > 1 << bitsPerPixel) {
        throw const ImageCodecException('BMP palette contains more entries than its bit depth can address');
      }
      // Writers sometimes stop the palette short of its declared length; trust
      // the space that actually precedes the pixel data.
      final int availableLength = pixelOffset > paletteOffset ? (pixelOffset - paletteOffset) ~/ entryLength : declaredLength;
      final int paletteLength = declaredLength < availableLength ? declaredLength : availableLength;
      metadataEnd = paletteOffset + paletteLength * entryLength;
      final InputBuffer paletteInput = InputBuffer(bytes)..seek(paletteOffset);
      palette = Int32List(paletteLength);
      for (int index = 0; index < paletteLength; index++) {
        final int blue = paletteInput.readUint8();
        final int green = paletteInput.readUint8();
        final int red = paletteInput.readUint8();
        if (entryLength == 4) {
          paletteInput.skip(1);
        }
        palette[index] = (red << 24) | (green << 16) | (blue << 8) | 0xff;
      }
    }

    if (pixelOffset < metadataEnd || pixelOffset > bytes.length) {
      throw const ImageCodecException('The BMP pixel data is truncated');
    }
    final Uint8List rgba = Uint8List(width * height * 4);
    if (compression == 1 || compression == 2) {
      _decodeRunLength(bytes, rgba, pixelOffset, width, height, palette!, fourBit: compression == 2);
      return Image.fromRgba(width: width, height: height, bytes: rgba, copy: false);
    }

    final int rowLength = ((width * bitsPerPixel + 31) ~/ 32) * 4;
    if (rowLength * height > bytes.length - pixelOffset) {
      throw const ImageCodecException('The BMP pixel data is truncated');
    }
    for (int sourceY = 0; sourceY < height; sourceY++) {
      final int destinationY = topDown ? sourceY : height - 1 - sourceY;
      final int rowOffset = pixelOffset + sourceY * rowLength;
      final int destination = destinationY * width * 4;
      switch (bitsPerPixel) {
        case 1 || 4 || 8:
          _readIndexedRow(bytes, rgba, rowOffset, destination, width, bitsPerPixel, palette!);
        case 24:
          _readDirectRow(bytes, rgba, rowOffset, destination, width);
        default:
          _readMaskedRow(bytes, rgba, rowOffset, destination, width, bitsPerPixel, redMask, greenMask, blueMask, alphaMask);
      }
    }

    if (bitsPerPixel == 32 && compression == 0 && _isFullyTransparent(rgba)) {
      // A plain 32-bit bitmap has no alpha channel, so an all-zero fourth byte
      // means unused padding rather than an invisible image.
      for (int offset = 3; offset < rgba.length; offset += 4) {
        rgba[offset] = 255;
      }
    }
    return Image.fromRgba(width: width, height: height, bytes: rgba, copy: false);
  }

  /// Expands one palette-indexed scanline.
  void _readIndexedRow(Uint8List bytes, Uint8List rgba, int rowOffset, int destination, int width, int bitsPerPixel, Int32List palette) {
    for (int x = 0; x < width; x++) {
      final int index = switch (bitsPerPixel) {
        1 => (bytes[rowOffset + (x >> 3)] >> (7 - (x & 7))) & 1,
        4 => (bytes[rowOffset + (x >> 1)] >> (x.isEven ? 4 : 0)) & 0x0f,
        _ => bytes[rowOffset + x],
      };
      if (index >= palette.length) {
        throw const ImageCodecException('BMP pixel references a missing palette entry');
      }
      _writePacked(rgba, destination + x * 4, palette[index]);
    }
  }

  /// Copies one 24-bit scanline, swapping its blue and red channels.
  void _readDirectRow(Uint8List bytes, Uint8List rgba, int rowOffset, int destination, int width) {
    int source = rowOffset;
    int target = destination;
    for (int x = 0; x < width; x++) {
      rgba[target] = bytes[source + 2];
      rgba[target + 1] = bytes[source + 1];
      rgba[target + 2] = bytes[source];
      rgba[target + 3] = 255;
      source += 3;
      target += 4;
    }
  }

  /// Expands one 16-bit or 32-bit scanline through its channel masks.
  void _readMaskedRow(
    Uint8List bytes,
    Uint8List rgba,
    int rowOffset,
    int destination,
    int width,
    int bitsPerPixel,
    int redMask,
    int greenMask,
    int blueMask,
    int alphaMask,
  ) {
    final int byteLength = bitsPerPixel ~/ 8;
    final _BmpChannel red = _BmpChannel(redMask);
    final _BmpChannel green = _BmpChannel(greenMask);
    final _BmpChannel blue = _BmpChannel(blueMask);
    final _BmpChannel alpha = _BmpChannel(alphaMask);
    int source = rowOffset;
    int target = destination;
    for (int x = 0; x < width; x++) {
      int value = 0;
      for (int byte = 0; byte < byteLength; byte++) {
        value |= bytes[source + byte] << (byte * 8);
      }
      rgba[target] = red.scale(value);
      rgba[target + 1] = green.scale(value);
      rgba[target + 2] = blue.scale(value);
      rgba[target + 3] = alphaMask == 0 ? (bitsPerPixel == 32 ? bytes[source + 3] : 255) : alpha.scale(value);
      source += byteLength;
      target += 4;
    }
  }

  /// Decodes four-bit or eight-bit run-length encoded pixel data.
  void _decodeRunLength(
    Uint8List bytes,
    Uint8List rgba,
    int pixelOffset,
    int width,
    int height,
    Int32List palette, {
    required bool fourBit,
  }) {
    final InputBuffer input = InputBuffer(bytes)..seek(pixelOffset);
    int x = 0;
    int y = 0;
    while (y < height) {
      final int count = input.readUint8();
      final int value = input.readUint8();
      if (count > 0) {
        _writeRun(rgba, palette, width, height, x, y, count, value, fourBit: fourBit);
        x += count;
        continue;
      }
      switch (value) {
        case 0:
          x = 0;
          y++;
        case 1:
          return;
        case 2:
          x += input.readUint8();
          y += input.readUint8();
        default:
          _writeLiteral(input, rgba, palette, width, height, x, y, value, fourBit: fourBit);
          x += value;
      }
    }
  }

  /// Writes one repeated run of palette indices.
  void _writeRun(
    Uint8List rgba,
    Int32List palette,
    int width,
    int height,
    int x,
    int y,
    int count,
    int value, {
    required bool fourBit,
  }) {
    for (int step = 0; step < count; step++) {
      final int index = fourBit ? (step.isEven ? value >> 4 : value & 0x0f) : value;
      _writeIndexed(rgba, palette, width, height, x + step, y, index);
    }
  }

  /// Writes one absolute run of palette indices and its padding.
  void _writeLiteral(
    InputBuffer input,
    Uint8List rgba,
    Int32List palette,
    int width,
    int height,
    int x,
    int y,
    int count, {
    required bool fourBit,
  }) {
    final int byteCount = fourBit ? (count + 1) ~/ 2 : count;
    final Uint8List data = input.readBytes(byteCount);
    for (int step = 0; step < count; step++) {
      final int index = fourBit ? (step.isEven ? data[step >> 1] >> 4 : data[step >> 1] & 0x0f) : data[step];
      _writeIndexed(rgba, palette, width, height, x + step, y, index);
    }
    if (byteCount.isOdd) {
      input.skip(1);
    }
  }

  /// Writes one bottom-up palette pixel, ignoring positions outside the image.
  void _writeIndexed(Uint8List rgba, Int32List palette, int width, int height, int x, int y, int index) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      return;
    }
    if (index >= palette.length) {
      throw const ImageCodecException('BMP pixel references a missing palette entry');
    }
    _writePacked(rgba, ((height - 1 - y) * width + x) * 4, palette[index]);
  }

  /// Unpacks one color into four consecutive RGBA bytes.
  void _writePacked(Uint8List rgba, int destination, int color) {
    rgba[destination] = (color >>> 24) & 0xff;
    rgba[destination + 1] = (color >>> 16) & 0xff;
    rgba[destination + 2] = (color >>> 8) & 0xff;
    rgba[destination + 3] = color & 0xff;
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

/// Scales one packed BMP bitfield channel to eight bits.
final class _BmpChannel {
  /// Bitfield mask selecting this channel.
  final int mask;

  /// Number of low bits to discard.
  final int shift;

  /// Largest value the channel can hold once shifted.
  final int maximum;

  /// Creates a scaler for [mask].
  factory _BmpChannel(int mask) {
    if (mask == 0) {
      return const _BmpChannel._(mask: 0, shift: 0, maximum: 0);
    }
    int shift = 0;
    int shifted = mask;
    while (shifted.isEven) {
      shifted >>>= 1;
      shift++;
    }
    return _BmpChannel._(mask: mask, shift: shift, maximum: shifted);
  }

  /// Creates a scaler from its derived fields.
  const _BmpChannel._({
    required this.mask,
    required this.shift,
    required this.maximum,
  });

  /// Extracts and scales this channel from a packed pixel [value].
  int scale(int value) => maximum == 0 ? 0 : (((value & mask) >>> shift) * 255 + (maximum >> 1)) ~/ maximum;
}
