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
    final Uint8List bytes = image.bytes;
    final OutputBuffer output = OutputBuffer(bigEndian: true)
      ..writeBytes(_magic)
      ..writeUint32(image.width)
      ..writeUint32(image.height)
      ..writeByte(_hasTransparency(bytes) ? 4 : 3)
      ..writeByte(0);
    // Colors stay packed in integers so that the running index and the pixel
    // loop never allocate.
    final Int32List index = Int32List(64);
    int previousRed = 0;
    int previousGreen = 0;
    int previousBlue = 0;
    int previousAlpha = 255;
    int run = 0;
    final int pixelCount = image.width * image.height;
    for (int pixel = 0; pixel < pixelCount; pixel++) {
      final int offset = pixel * 4;
      final int red = bytes[offset];
      final int green = bytes[offset + 1];
      final int blue = bytes[offset + 2];
      final int alpha = bytes[offset + 3];
      if (red == previousRed && green == previousGreen && blue == previousBlue && alpha == previousAlpha) {
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

      final int packed = (red << 24) | (green << 16) | (blue << 8) | alpha;
      final int indexPosition = (red * 3 + green * 5 + blue * 7 + alpha * 11) & 63;
      if (index[indexPosition] == packed) {
        output.writeByte(indexPosition);
      } else {
        index[indexPosition] = packed;
        if (alpha == previousAlpha) {
          // Differences wrap around like the reference encoder's signed bytes,
          // which lets values that cross zero still use the compact opcodes.
          final int redDifference = _wrap(red - previousRed);
          final int greenDifference = _wrap(green - previousGreen);
          final int blueDifference = _wrap(blue - previousBlue);
          final int redGreenDifference = _wrap(redDifference - greenDifference);
          final int blueGreenDifference = _wrap(blueDifference - greenDifference);
          if (redDifference >= -2 && redDifference <= 1 && greenDifference >= -2 && greenDifference <= 1 && blueDifference >= -2 && blueDifference <= 1) {
            output.writeByte(0x40 | ((redDifference + 2) << 4) | ((greenDifference + 2) << 2) | (blueDifference + 2));
          } else if (greenDifference >= -32 && greenDifference <= 31 && redGreenDifference >= -8 && redGreenDifference <= 7 && blueGreenDifference >= -8 && blueGreenDifference <= 7) {
            output
              ..writeByte(0x80 | (greenDifference + 32))
              ..writeByte((redGreenDifference + 8) << 4 | (blueGreenDifference + 8));
          } else {
            output
              ..writeByte(0xfe)
              ..writeByte(red)
              ..writeByte(green)
              ..writeByte(blue);
          }
        } else {
          output
            ..writeByte(0xff)
            ..writeByte(red)
            ..writeByte(green)
            ..writeByte(blue)
            ..writeByte(alpha);
        }
      }
      previousRed = red;
      previousGreen = green;
      previousBlue = blue;
      previousAlpha = alpha;
    }
    output.writeBytes(_endMarker);
    return output.takeBytes();
  }

  /// Reduces a channel difference to the signed byte range.
  static int _wrap(int difference) => ((difference + 128) & 0xff) - 128;

  /// Reports whether any source pixel uses transparency.
  bool _hasTransparency(Uint8List bytes) {
    for (int offset = 3; offset < bytes.length; offset += 4) {
      if (bytes[offset] != 255) {
        return true;
      }
    }
    return false;
  }
}
