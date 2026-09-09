part of 'image_format.dart';

/// Portable Network Graphics format.
final class _PngFormat extends ImageFormat with InspectableFormat {
  /// Creates a Portable Network Graphics format.
  const _PngFormat() : super(name: 'png');

  @override
  bool matches(Uint8List bytes) =>
      bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47 && bytes[4] == 0x0d && bytes[5] == 0x0a && bytes[6] == 0x1a && bytes[7] == 0x0a;

  @override
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes) {
    if (bytes.lengthInBytes < 33) {
      throw const ImageCodecException('The PNG header is truncated');
    }
    final ByteData data = ByteData.sublistView(bytes);
    int? width;
    int? height;
    int? bitsPerChannel;
    Uint8List? iccProfile;
    Uint8List? exifMetadata;
    Uint8List? xmpMetadata;
    int position = 8;
    while (position < bytes.lengthInBytes) {
      if (position > bytes.lengthInBytes - 12) {
        throw const ImageCodecException('The PNG chunk header is truncated');
      }
      final int length = data.getUint32(position, Endian.big);
      final int typeOffset = position + 4;
      final int payloadOffset = typeOffset + 4;
      if (length > bytes.lengthInBytes - payloadOffset - 4) {
        throw const ImageCodecException('The PNG chunk payload is truncated');
      }
      final String type = String.fromCharCodes(
        bytes,
        typeOffset,
        typeOffset + 4,
      );
      if (type == 'IHDR') {
        if (length != 13 || width != null) {
          throw const ImageCodecException('PNG has an invalid image header');
        }
        width = data.getUint32(payloadOffset, Endian.big);
        height = data.getUint32(payloadOffset + 4, Endian.big);
        bitsPerChannel = bytes[payloadOffset + 8];
      } else if (type == 'iCCP') {
        if (iccProfile != null) {
          throw const ImageCodecException(
            'PNG contains more than one ICC profile',
          );
        }
        final int payloadEnd = payloadOffset + length;
        int separator = payloadOffset;
        while (separator < payloadEnd && bytes[separator] != 0) {
          separator++;
        }
        final int nameLength = separator - payloadOffset;
        if (nameLength < 1 || nameLength > 79 || separator + 2 > payloadEnd || bytes[separator + 1] != 0) {
          throw const ImageCodecException('PNG has an invalid ICC chunk');
        }
        try {
          iccProfile =
              ZlibCodec(
                maxOutputBytes: maxIccProfileBytes,
              ).decode(
                Uint8List.sublistView(bytes, separator + 2, payloadEnd),
              );
        } on Object catch (error) {
          throw ImageCodecException(
            'Could not decompress the PNG ICC profile',
            cause: error,
          );
        }
      } else if (type == 'eXIf') {
        exifMetadata = _boundedPacket(
          bytes,
          payloadOffset,
          length,
          maximumBytes: maxDescriptiveMetadataBytes,
          label: 'PNG EXIF',
        );
      } else if (type == 'iTXt') {
        final Uint8List? packet = _pngXmpPacket(
          bytes,
          payloadOffset,
          length,
          maxDescriptiveMetadataBytes,
        );
        xmpMetadata = packet ?? xmpMetadata;
      }
      position = payloadOffset + length + 4;
      if (type == 'IEND') {
        break;
      }
    }
    if (width == null || height == null || bitsPerChannel == null) {
      throw const ImageCodecException('PNG is missing its image header');
    }
    return DecodedImageMetadata(
      width: width,
      height: height,
      bitsPerChannel: bitsPerChannel,
      colorModel: DecodedColorModel.rgb,
      iccProfile: iccProfile,
      exifMetadata: exifMetadata,
      xmpMetadata: xmpMetadata,
    );
  }

  /// Decodes the standardized PNG international-text XMP payload.
  Uint8List? _pngXmpPacket(Uint8List bytes, int offset, int length, int maximumBytes) {
    final int end = offset + length;
    final int keywordEnd = _zeroByte(bytes, offset, end);
    if (keywordEnd < 0 || String.fromCharCodes(bytes, offset, keywordEnd) != 'XML:com.adobe.xmp' || keywordEnd + 3 > end) {
      return null;
    }
    final int compressionFlag = bytes[keywordEnd + 1];
    final int compressionMethod = bytes[keywordEnd + 2];
    int cursor = keywordEnd + 3;
    final int languageEnd = _zeroByte(bytes, cursor, end);
    if (languageEnd < 0) {
      return null;
    }
    cursor = languageEnd + 1;
    final int translatedEnd = _zeroByte(bytes, cursor, end);
    if (translatedEnd < 0) {
      return null;
    }
    cursor = translatedEnd + 1;
    if (compressionFlag == 0) {
      return _boundedPacket(
        bytes,
        cursor,
        end - cursor,
        maximumBytes: maximumBytes,
        label: 'PNG XMP',
      );
    }
    if (compressionFlag != 1 || compressionMethod != 0) {
      throw const ImageCodecException('PNG XMP uses unsupported compression');
    }
    try {
      return ZlibCodec(maxOutputBytes: maximumBytes).decode(
        Uint8List.sublistView(bytes, cursor, end),
      );
    } on Object catch (error) {
      throw ImageCodecException('Could not decompress PNG XMP', cause: error);
    }
  }
}
