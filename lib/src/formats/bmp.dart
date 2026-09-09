part of 'image_format.dart';

/// Windows bitmap format.
final class _BmpFormat extends ImageFormat {
  /// Creates a Windows bitmap format.
  const _BmpFormat() : super(name: 'bmp');

  @override
  bool matches(Uint8List bytes) => bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d;
}
