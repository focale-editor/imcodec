part of '../qoi.dart';

/// Encodes RGBA pixels using the Quite OK Image specification.
final class QoiEncoder extends RasterEncoder {
  /// Four-byte QOI file signature.
  static const List<int> _magic = [0x71, 0x6f, 0x69, 0x66];

  /// Fixed marker terminating every QOI stream.
  static const List<int> _endMarker = [0, 0, 0, 0, 0, 0, 0, 1];

  /// Creates a QOI encoder.
  const QoiEncoder();

  /// Encodes [image] losslessly in the sRGB color space.
  @override
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
    final List<_QoiColor> index = List<_QoiColor>.filled(64, const _QoiColor(red: 0, green: 0, blue: 0, alpha: 0));
    _QoiColor previous = const _QoiColor(red: 0, green: 0, blue: 0, alpha: 255);
    int run = 0;
    final int pixelCount = image.width * image.height;
    for (int pixel = 0; pixel < pixelCount; pixel++) {
      final int offset = pixel * 4;
      final _QoiColor color = _QoiColor(
        red: image.bytes[offset],
        green: image.bytes[offset + 1],
        blue: image.bytes[offset + 2],
        alpha: image.bytes[offset + 3],
      );
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
