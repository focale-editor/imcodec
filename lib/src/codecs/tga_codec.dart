import 'dart:typed_data';

import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/input_buffer.dart';
import 'package:imcodec/src/output_buffer.dart';

/// Encodes RGBA pixels as 32-bit true-color TGA data.
final class TgaEncoder {
  /// TGA 2.0 footer signature.
  static const List<int> _footerSignature = [0x54, 0x52, 0x55, 0x45, 0x56, 0x49, 0x53, 0x49, 0x4f, 0x4e, 0x2d, 0x58, 0x46, 0x49, 0x4c, 0x45, 0x2e, 0x00];

  /// Creates a TGA encoder.
  const TgaEncoder();

  /// Encodes [image], optionally using TGA run-length encoding.
  Uint8List encode(Image image, {bool runLengthEncoding = true}) {
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

/// Decodes color-mapped, true-color, and grayscale TGA images.
final class TgaDecoder {
  /// Creates a TGA decoder.
  const TgaDecoder();

  /// Decodes uncompressed or run-length encoded TGA data.
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
    final List<_TgaColor> colorMap = [];
    if (colorMapped) {
      if (![15, 16, 24, 32].contains(colorMapDepth)) {
        throw ImageCodecException('Unsupported TGA color-map depth: $colorMapDepth');
      }
      for (int index = 0; index < colorMapLength; index++) {
        colorMap.add(_readDirectColor(input, colorMapDepth, hasAlphaBit: colorMapDepth == 16));
      }
    }

    final Uint8List rgba = Uint8List(width * height * 4);
    int decodedPixels = 0;
    while (decodedPixels < width * height) {
      final int packetLength = runLengthEncoded ? (input.readUint8() & 0x7f) + 1 : 1;
      final bool repeatedPacket = runLengthEncoded && (bytes[input.position - 1] & 0x80) != 0;
      if (packetLength > width * height - decodedPixels) {
        throw const ImageCodecException('A TGA packet exceeds the declared image dimensions');
      }
      if (repeatedPacket) {
        final _TgaColor color = _readColor(input, colorMapped, grayscale, pixelDepth, colorMapOrigin, colorMap, descriptor);
        for (int count = 0; count < packetLength; count++) {
          _storeColor(rgba, decodedPixels++, width, height, descriptor, color);
        }
      } else {
        for (int count = 0; count < packetLength; count++) {
          final _TgaColor color = _readColor(input, colorMapped, grayscale, pixelDepth, colorMapOrigin, colorMap, descriptor);
          _storeColor(rgba, decodedPixels++, width, height, descriptor, color);
        }
      }
    }
    return Image.fromRgba(width: width, height: height, bytes: rgba, copy: false);
  }

  /// Reads a direct, grayscale, or palette-indexed TGA color.
  _TgaColor _readColor(
    InputBuffer input,
    bool colorMapped,
    bool grayscale,
    int pixelDepth,
    int colorMapOrigin,
    List<_TgaColor> colorMap,
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
      return _TgaColor(gray, gray, gray, alpha);
    }
    return _readDirectColor(input, pixelDepth, hasAlphaBit: (descriptor & 0x0f) != 0);
  }

  /// Reads a packed or byte-aligned TGA true color.
  _TgaColor _readDirectColor(InputBuffer input, int depth, {required bool hasAlphaBit}) {
    if (depth == 15 || depth == 16) {
      final int value = input.readUint16();
      final int red = ((value >>> 10) & 0x1f) * 255 ~/ 31;
      final int green = ((value >>> 5) & 0x1f) * 255 ~/ 31;
      final int blue = (value & 0x1f) * 255 ~/ 31;
      final int alpha = depth == 16 && hasAlphaBit ? ((value & 0x8000) == 0 ? 0 : 255) : 255;
      return _TgaColor(red, green, blue, alpha);
    }
    final int blue = input.readUint8();
    final int green = input.readUint8();
    final int red = input.readUint8();
    final int alpha = depth == 32 ? input.readUint8() : 255;
    return _TgaColor(red, green, blue, alpha);
  }

  /// Maps stream order and origin flags to the normalized top-left layout.
  void _storeColor(Uint8List rgba, int streamIndex, int width, int height, int descriptor, _TgaColor color) {
    final int streamY = streamIndex ~/ width;
    final int streamX = streamIndex - streamY * width;
    final int x = (descriptor & 0x10) == 0 ? streamX : width - 1 - streamX;
    final int y = (descriptor & 0x20) != 0 ? streamY : height - 1 - streamY;
    final int offset = (y * width + x) * 4;
    rgba[offset] = color.red;
    rgba[offset + 1] = color.green;
    rgba[offset + 2] = color.blue;
    rgba[offset + 3] = color.alpha;
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

/// Holds one decoded TGA color.
final class _TgaColor {
  /// Red channel.
  final int red;

  /// Green channel.
  final int green;

  /// Blue channel.
  final int blue;

  /// Alpha channel.
  final int alpha;

  /// Creates a color from eight-bit channels.
  const _TgaColor(this.red, this.green, this.blue, this.alpha);
}
