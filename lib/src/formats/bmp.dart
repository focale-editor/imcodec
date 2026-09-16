part of 'image_format.dart';

/// Windows bitmap format.
final class _BmpFormat extends ImageFormat with InspectableFormat {
  /// Creates a Windows bitmap format.
  const _BmpFormat() : super(name: 'bmp');

  @override
  bool matches(Uint8List bytes) => bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d;

  @override
  DecodedImageMetadata inspect(
    Uint8List bytes,
    int maxIccProfileBytes,
    int maxDescriptiveMetadataBytes,
  ) {
    if (bytes.lengthInBytes < 54 || !matches(bytes)) {
      throw const ImageCodecException('The BMP header is truncated');
    }
    final ByteData data = ByteData.sublistView(bytes);
    final int headerSize = data.getUint32(14, Endian.little);
    if (headerSize < 40 || bytes.lengthInBytes < 14 + headerSize) {
      throw const ImageCodecException('Unsupported BMP information header');
    }
    final int width = data.getInt32(18, Endian.little);
    final int signedHeight = data.getInt32(22, Endian.little);
    final int bitsPerPixel = data.getUint16(28, Endian.little);
    if (width < 1 || signedHeight == 0) {
      throw const ImageCodecException('BMP has invalid image dimensions');
    }
    final int horizontalPixelsPerMeter = data.getInt32(38, Endian.little);
    final int verticalPixelsPerMeter = data.getInt32(42, Endian.little);
    return DecodedImageMetadata(
      width: width,
      height: signedHeight.abs(),
      bitsPerChannel: bitsPerPixel >= 24 ? 8 : bitsPerPixel,
      colorModel: DecodedColorModel.rgb,
      horizontalPixelsPerInch: horizontalPixelsPerMeter > 0 ? horizontalPixelsPerMeter / 39.37007874015748 : null,
      verticalPixelsPerInch: verticalPixelsPerMeter > 0 ? verticalPixelsPerMeter / 39.37007874015748 : null,
    );
  }
}
