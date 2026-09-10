part of 'image_format.dart';

/// Quite OK Image format.
final class _QoiFormat extends ImageFormat with InspectableFormat {
  /// Bytes of the fixed QOI header, signature and description together.
  static const int _headerLength = 14;

  /// Creates a Quite OK Image format.
  const _QoiFormat() : super(name: 'qoi');

  @override
  bool matches(Uint8List bytes) => bytes.length >= 4 && bytes[0] == 0x71 && bytes[1] == 0x6f && bytes[2] == 0x69 && bytes[3] == 0x66;

  @override
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes) {
    if (bytes.lengthInBytes < _headerLength) {
      throw const ImageCodecException('The QOI header is truncated');
    }
    final ByteData data = ByteData.sublistView(bytes);
    final int width = data.getUint32(4, Endian.big);
    final int height = data.getUint32(8, Endian.big);
    final int channels = bytes[12];
    if (width == 0 || height == 0) {
      throw const ImageCodecException('QOI declares an empty image');
    }
    if (channels != 3 && channels != 4) {
      throw const ImageCodecException('QOI declares an unsupported channel count');
    }
    // QOI carries no profile and no descriptive packets: three or four
    // eight-bit channels, and a colour space byte that only distinguishes
    // sRGB from all-linear without naming a profile to preserve.
    return DecodedImageMetadata(
      width: width,
      height: height,
      bitsPerChannel: 8,
      colorModel: DecodedColorModel.rgb,
    );
  }
}
