part of 'image_format.dart';

/// Quite OK Image format.
final class _QoiFormat extends ImageFormat {
  /// Creates a Quite OK Image format.
  const _QoiFormat() : super(name: 'qoi');

  @override
  bool matches(Uint8List bytes) => bytes.length >= 4 && bytes[0] == 0x71 && bytes[1] == 0x6f && bytes[2] == 0x69 && bytes[3] == 0x66;
}
