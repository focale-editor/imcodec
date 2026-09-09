part of 'image_format.dart';

/// Graphics Interchange Format format.
final class _GifFormat extends ImageFormat {
  /// Creates a Graphics Interchange Format format.
  const _GifFormat() : super(name: 'gif');

  @override
  bool matches(Uint8List bytes) => bytes.length >= 6 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 && (bytes[4] == 0x37 || bytes[4] == 0x39) && bytes[5] == 0x61;
}
