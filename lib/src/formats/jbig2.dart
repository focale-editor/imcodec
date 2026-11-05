part of 'image_format.dart';

/// Signature matcher for standalone JBIG2 files.
final class _Jbig2Format extends ImageFormat with InspectableFormat {
  /// Creates the canonical JBIG2 format.
  const _Jbig2Format() : super(name: 'jbig2');

  @override
  bool matches(Uint8List bytes) =>
      bytes.length >= 8 && bytes[0] == 0x97 && bytes[1] == 0x4a && bytes[2] == 0x42 && bytes[3] == 0x32 && bytes[4] == 0x0d && bytes[5] == 0x0a && bytes[6] == 0x1a && bytes[7] == 0x0a;
  @override
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes) => inspectJbig2Container(bytes);
}
