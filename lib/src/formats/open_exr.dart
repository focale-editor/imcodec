part of 'image_format.dart';

/// OpenEXR format.
final class _OpenExrFormat extends ImageFormat {
  /// Creates an OpenEXR format.
  const _OpenExrFormat() : super(name: 'openExr');

  @override
  bool matches(Uint8List bytes) => bytes.length >= 4 && bytes[0] == 0x76 && bytes[1] == 0x2f && bytes[2] == 0x31 && bytes[3] == 0x01;
}
