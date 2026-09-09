part of 'image_format.dart';

/// JPEG XL codestream or container format.
final class _JpegXlFormat extends ImageFormat {
  /// Creates a JPEG XL codestream or container format.
  const _JpegXlFormat() : super(name: 'jpegXl');

  @override
  bool matches(Uint8List bytes) =>
      (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0x0a) ||
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
          bytes[11] == 0x0a);
}
