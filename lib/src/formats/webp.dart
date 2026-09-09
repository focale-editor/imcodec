part of 'image_format.dart';

/// WebP Resource Interchange format.
final class _WebPFormat extends ImageFormat with InspectableFormat {
  /// Creates a WebP Resource Interchange format.
  const _WebPFormat() : super(name: 'webp');

  @override
  bool matches(Uint8List bytes) =>
      bytes.length >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50;

  @override
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes) {
    if (bytes.lengthInBytes < 20 || !_matchesAscii(bytes, 0, 'RIFF') || !_matchesAscii(bytes, 8, 'WEBP')) {
      throw const ImageCodecException('Invalid WebP RIFF header');
    }
    final int declaredLength = _littleUint32(bytes, 4) + 8;
    if (declaredLength < 20 || declaredLength > bytes.lengthInBytes) {
      throw const ImageCodecException('The WebP RIFF payload is truncated');
    }
    int? width;
    int? height;
    Uint8List? iccProfile;
    Uint8List? exifMetadata;
    Uint8List? xmpMetadata;
    int position = 12;
    while (position < declaredLength) {
      if (position > declaredLength - 8) {
        throw const ImageCodecException('The WebP chunk header is truncated');
      }
      final String type = String.fromCharCodes(bytes, position, position + 4);
      final int length = _littleUint32(bytes, position + 4);
      final int payload = position + 8;
      final int paddedLength = length + (length & 1);
      if (length > declaredLength - payload || paddedLength > declaredLength - payload) {
        throw const ImageCodecException('The WebP chunk payload is truncated');
      }
      if (type == 'VP8X') {
        if (length != 10) {
          throw const ImageCodecException('Invalid WebP extended header');
        }
        width = _littleUint24(bytes, payload + 4) + 1;
        height = _littleUint24(bytes, payload + 7) + 1;
      } else if (type == 'ICCP') {
        if (iccProfile != null || length > maxIccProfileBytes) {
          throw const ImageCodecException('WebP has an invalid ICC profile');
        }
        iccProfile = Uint8List.fromList(
          Uint8List.sublistView(bytes, payload, payload + length),
        );
      } else if (type == 'EXIF') {
        exifMetadata = _boundedPacket(
          bytes,
          payload,
          length,
          maximumBytes: maxDescriptiveMetadataBytes,
          label: 'WebP EXIF',
        );
      } else if (type == 'XMP ') {
        xmpMetadata = _boundedPacket(
          bytes,
          payload,
          length,
          maximumBytes: maxDescriptiveMetadataBytes,
          label: 'WebP XMP',
        );
      } else if (width == null && type == 'VP8L' && length >= 5) {
        width = 1 + (bytes[payload + 1] | ((bytes[payload + 2] & 0x3f) << 8));
        height = 1 + (((bytes[payload + 2] >>> 6) | (bytes[payload + 3] << 2) | ((bytes[payload + 4] & 0x0f) << 10)) & 0x3fff);
      } else if (width == null && type == 'VP8 ' && length >= 10) {
        width = (bytes[payload + 6] | (bytes[payload + 7] << 8)) & 0x3fff;
        height = (bytes[payload + 8] | (bytes[payload + 9] << 8)) & 0x3fff;
      }
      position = payload + paddedLength;
    }
    if (width == null || height == null) {
      throw const ImageCodecException('WebP is missing image dimensions');
    }
    return DecodedImageMetadata(
      width: width,
      height: height,
      bitsPerChannel: 8,
      colorModel: DecodedColorModel.rgb,
      iccProfile: iccProfile,
      exifMetadata: exifMetadata,
      xmpMetadata: xmpMetadata,
    );
  }
}
