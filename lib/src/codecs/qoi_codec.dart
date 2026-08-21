import 'dart:typed_data';

import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/input_buffer.dart';
import 'package:imcodec/src/output_buffer.dart';

/// Encodes RGBA pixels using the Quite OK Image specification.
final class QoiEncoder {
  /// Four-byte QOI file signature.
  static const List<int> _magic = [0x71, 0x6f, 0x69, 0x66];

  /// Fixed marker terminating every QOI stream.
  static const List<int> _endMarker = [0, 0, 0, 0, 0, 0, 0, 1];

  /// Creates a QOI encoder.
  const QoiEncoder();

  /// Encodes [image] losslessly in the sRGB color space.
  Uint8List encode(Image image) {
    if (image.width > 0xffffffff || image.height > 0xffffffff) {
      throw const ImageCodecException('QOI dimensions may not exceed 4294967295 pixels');
    }
    final OutputBuffer output = OutputBuffer(bigEndian: true)
      ..writeBytes(_magic)
      ..writeUint32(image.width)
      ..writeUint32(image.height)
      ..writeByte(_hasTransparency(image) ? 4 : 3)
      ..writeByte(0);
    final List<_QoiColor> index = List<_QoiColor>.filled(64, const _QoiColor(0, 0, 0, 0));
    _QoiColor previous = const _QoiColor(0, 0, 0, 255);
    int run = 0;
    final int pixelCount = image.width * image.height;
    for (int pixel = 0; pixel < pixelCount; pixel++) {
      final int offset = pixel * 4;
      final _QoiColor color = _QoiColor(image.bytes[offset], image.bytes[offset + 1], image.bytes[offset + 2], image.bytes[offset + 3]);
      if (color == previous) {
        run++;
        if (run == 62 || pixel == pixelCount - 1) {
          output.writeByte(0xc0 | (run - 1));
          run = 0;
        }
        continue;
      }
      if (run > 0) {
        output.writeByte(0xc0 | (run - 1));
        run = 0;
      }

      final int indexPosition = color.hashPosition;
      if (index[indexPosition] == color) {
        output.writeByte(indexPosition);
      } else {
        index[indexPosition] = color;
        if (color.alpha == previous.alpha) {
          final int redDifference = color.red - previous.red;
          final int greenDifference = color.green - previous.green;
          final int blueDifference = color.blue - previous.blue;
          final int redGreenDifference = redDifference - greenDifference;
          final int blueGreenDifference = blueDifference - greenDifference;
          if (redDifference >= -2 && redDifference <= 1 && greenDifference >= -2 && greenDifference <= 1 && blueDifference >= -2 && blueDifference <= 1) {
            output.writeByte(0x40 | ((redDifference + 2) << 4) | ((greenDifference + 2) << 2) | (blueDifference + 2));
          } else if (greenDifference >= -32 && greenDifference <= 31 && redGreenDifference >= -8 && redGreenDifference <= 7 && blueGreenDifference >= -8 && blueGreenDifference <= 7) {
            output
              ..writeByte(0x80 | (greenDifference + 32))
              ..writeByte((redGreenDifference + 8) << 4 | (blueGreenDifference + 8));
          } else {
            output
              ..writeByte(0xfe)
              ..writeByte(color.red)
              ..writeByte(color.green)
              ..writeByte(color.blue);
          }
        } else {
          output
            ..writeByte(0xff)
            ..writeByte(color.red)
            ..writeByte(color.green)
            ..writeByte(color.blue)
            ..writeByte(color.alpha);
        }
      }
      previous = color;
    }
    output.writeBytes(_endMarker);
    return Uint8List.fromList(output.getBytes());
  }

  /// Reports whether any source pixel uses transparency.
  bool _hasTransparency(Image image) {
    for (int offset = 3; offset < image.bytes.length; offset += 4) {
      if (image.bytes[offset] != 255) {
        return true;
      }
    }
    return false;
  }
}

/// Decodes Quite OK Image data to RGBA pixels.
final class QoiDecoder {
  /// Creates a QOI decoder.
  const QoiDecoder();

  /// Decodes one complete QOI image.
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
    final List<_QoiColor> index = List<_QoiColor>.filled(64, const _QoiColor(0, 0, 0, 0));
    _QoiColor color = const _QoiColor(0, 0, 0, 255);
    int pixel = 0;
    while (pixel < pixelCount) {
      final int opcode = input.readUint8();
      int run = 1;
      if (opcode == 0xfe) {
        color = _QoiColor(input.readUint8(), input.readUint8(), input.readUint8(), color.alpha);
      } else if (opcode == 0xff) {
        color = _QoiColor(input.readUint8(), input.readUint8(), input.readUint8(), input.readUint8());
      } else {
        switch (opcode & 0xc0) {
          case 0x00:
            color = index[opcode & 0x3f];
          case 0x40:
            color = _QoiColor(
              (color.red + ((opcode >>> 4) & 0x03) - 2) & 0xff,
              (color.green + ((opcode >>> 2) & 0x03) - 2) & 0xff,
              (color.blue + (opcode & 0x03) - 2) & 0xff,
              color.alpha,
            );
          case 0x80:
            final int second = input.readUint8();
            final int greenDifference = (opcode & 0x3f) - 32;
            color = _QoiColor(
              (color.red + greenDifference + (second >>> 4) - 8) & 0xff,
              (color.green + greenDifference) & 0xff,
              (color.blue + greenDifference + (second & 0x0f) - 8) & 0xff,
              color.alpha,
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
  const _QoiColor(this.red, this.green, this.blue, this.alpha);

  /// Index specified by the QOI color hash.
  int get hashPosition => (red * 3 + green * 5 + blue * 7 + alpha * 11) % 64;

  @override
  bool operator ==(Object other) => other is _QoiColor && red == other.red && green == other.green && blue == other.blue && alpha == other.alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);
}
