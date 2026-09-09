part of 'image_format.dart';

/// Joint Photographic Experts Group format.
final class _JpegFormat extends ImageFormat with InspectableFormat {
  /// Standard JPEG APP1 prefix preceding an XMP packet.
  static final Uint8List _jpegXmpHeader = Uint8List.fromList(
    'http://ns.adobe.com/xap/1.0/\u0000'.codeUnits,
  );

  /// Creates a Joint Photographic Experts Group format.
  const _JpegFormat() : super(name: 'jpeg');

  @override
  bool matches(Uint8List bytes) => bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;

  @override
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes) {
    if (bytes.lengthInBytes < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
      throw const ImageCodecException('Invalid JPEG signature');
    }
    final Map<int, Uint8List> chunks = {};
    int expectedChunks = 0;
    int totalProfileBytes = 0;
    int? width;
    int? height;
    int? bitsPerChannel;
    int? componentCount;
    Uint8List? exifMetadata;
    Uint8List? iptcMetadata;
    Uint8List? xmpMetadata;
    int offset = 2;
    while (offset < bytes.lengthInBytes) {
      while (offset < bytes.lengthInBytes && bytes[offset] != 0xff) {
        offset++;
      }
      while (offset < bytes.lengthInBytes && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.lengthInBytes) {
        break;
      }
      final int marker = bytes[offset++];
      if (marker == 0xd9 || marker == 0xda) {
        break;
      }
      if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd7) {
        continue;
      }
      if (offset > bytes.lengthInBytes - 2) {
        throw const ImageCodecException('The JPEG segment header is truncated');
      }
      final int segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
      if (segmentLength < 2 || offset > bytes.lengthInBytes - segmentLength) {
        throw const ImageCodecException('The JPEG segment payload is truncated');
      }
      final int payload = offset + 2;
      final int payloadLength = segmentLength - 2;
      if (_isJpegFrameMarker(marker)) {
        if (payloadLength < 6) {
          throw const ImageCodecException('The JPEG frame header is truncated');
        }
        bitsPerChannel = bytes[payload];
        height = (bytes[payload + 1] << 8) | bytes[payload + 2];
        width = (bytes[payload + 3] << 8) | bytes[payload + 4];
        componentCount = bytes[payload + 5];
      } else if (marker == 0xe2 && payloadLength >= 14 && _matchesAscii(bytes, payload, 'ICC_PROFILE\u0000')) {
        final int sequence = bytes[payload + 12];
        final int count = bytes[payload + 13];
        if (sequence < 1 || count < 1 || sequence > count || expectedChunks != 0 && count != expectedChunks || chunks.containsKey(sequence)) {
          throw const ImageCodecException('JPEG has invalid ICC chunk ordering');
        }
        expectedChunks = count;
        final Uint8List chunk = Uint8List.fromList(
          bytes.sublist(payload + 14, offset + segmentLength),
        );
        totalProfileBytes += chunk.lengthInBytes;
        if (totalProfileBytes > maxIccProfileBytes) {
          throw const ImageCodecException(
            'The JPEG ICC profile exceeds the configured limit',
          );
        }
        chunks[sequence] = chunk;
      } else if (marker == 0xe1 && payloadLength >= 6 && _matchesAscii(bytes, payload, 'Exif\u0000\u0000')) {
        exifMetadata = _boundedPacket(
          bytes,
          payload,
          payloadLength,
          maximumBytes: maxDescriptiveMetadataBytes,
          label: 'JPEG EXIF',
        );
      } else if (marker == 0xe1 && payloadLength >= _jpegXmpHeader.length && _matchesBytes(bytes, payload, _jpegXmpHeader)) {
        xmpMetadata = _boundedPacket(
          bytes,
          payload + _jpegXmpHeader.length,
          payloadLength - _jpegXmpHeader.length,
          maximumBytes: maxDescriptiveMetadataBytes,
          label: 'JPEG XMP',
        );
      } else if (marker == 0xed) {
        final Uint8List? packet = _jpegIptcPacket(
          bytes,
          payload,
          payloadLength,
          maxDescriptiveMetadataBytes,
        );
        iptcMetadata = packet ?? iptcMetadata;
      }
      offset += segmentLength;
    }
    if (width == null || height == null || bitsPerChannel == null || componentCount == null) {
      throw const ImageCodecException('JPEG is missing its frame header');
    }
    final Uint8List? iccProfile = _joinIccChunks(
      chunks,
      expectedChunks,
      totalProfileBytes,
    );
    return DecodedImageMetadata(
      width: width,
      height: height,
      bitsPerChannel: bitsPerChannel,
      colorModel: componentCount == 4 ? DecodedColorModel.cmyk : DecodedColorModel.rgb,
      iccProfile: iccProfile,
      exifMetadata: exifMetadata,
      iptcMetadata: iptcMetadata,
      xmpMetadata: xmpMetadata,
    );
  }

  /// Extracts IPTC resource `0x0404` from a Photoshop APP13 payload.
  Uint8List? _jpegIptcPacket(
    Uint8List bytes,
    int offset,
    int length,
    int maximumBytes,
  ) {
    const String header = 'Photoshop 3.0\u0000';
    if (length < header.length || !_matchesAscii(bytes, offset, header)) {
      return null;
    }
    final ByteData data = ByteData.sublistView(bytes);
    final int end = offset + length;
    int cursor = offset + header.length;
    while (cursor <= end - 12) {
      if (!_matchesAscii(bytes, cursor, '8BIM')) {
        return null;
      }
      final int resourceId = data.getUint16(cursor + 4, Endian.big);
      final int nameLength = bytes[cursor + 6];
      final int nameBytes = nameLength + 1;
      cursor += 6 + nameBytes + (nameBytes.isOdd ? 1 : 0);
      if (cursor > end - 4) {
        return null;
      }
      final int resourceLength = data.getUint32(cursor, Endian.big);
      cursor += 4;
      if (resourceLength > end - cursor) {
        return null;
      }
      if (resourceId == 0x0404) {
        return _boundedPacket(
          bytes,
          cursor,
          resourceLength,
          maximumBytes: maximumBytes,
          label: 'JPEG IPTC',
        );
      }
      cursor += resourceLength + (resourceLength.isOdd ? 1 : 0);
    }
    return null;
  }

  /// Tests a byte range against an exact byte sequence.
  bool _matchesBytes(Uint8List bytes, int offset, Uint8List expected) {
    if (offset < 0 || offset > bytes.lengthInBytes - expected.lengthInBytes) {
      return false;
    }
    for (int index = 0; index < expected.lengthInBytes; index++) {
      if (bytes[offset + index] != expected[index]) {
        return false;
      }
    }
    return true;
  }

  /// Whether [marker] starts a JPEG frame carrying precision and dimensions.
  bool _isJpegFrameMarker(int marker) => marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc;

  /// Joins a complete set of ordered ICC chunks.
  Uint8List? _joinIccChunks(
    Map<int, Uint8List> chunks,
    int expectedChunks,
    int length,
  ) {
    if (expectedChunks == 0) {
      return null;
    }
    if (chunks.length != expectedChunks) {
      throw const ImageCodecException('The JPEG ICC profile is incomplete');
    }
    final Uint8List result = Uint8List(length);
    int offset = 0;
    for (int sequence = 1; sequence <= expectedChunks; sequence++) {
      final Uint8List? chunk = chunks[sequence];
      if (chunk == null) {
        throw const ImageCodecException('The JPEG ICC profile is incomplete');
      }
      result.setAll(offset, chunk);
      offset += chunk.lengthInBytes;
    }
    return result;
  }
}
