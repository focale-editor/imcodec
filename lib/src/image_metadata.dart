import 'dart:typed_data';

import 'package:imcodec/src/decoded_image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';
import 'package:zcodec/zcodec.dart';

/// Default maximum number of decompressed ICC bytes retained from a container.
const int defaultMaxIccProfileBytes = 16 * 1024 * 1024;

/// Reads metadata needed to preserve authored samples and colour meaning.
///
/// `null` means the format has no metadata-aware reader yet. Pixel decoding is
/// deliberately separate so callers can keep a platform fast path for ordinary
/// untagged eight-bit images.
DecodedImageMetadata? inspectImage(
  Uint8List bytes, {
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) {
  if (maxIccProfileBytes < 1) {
    throw RangeError.range(
      maxIccProfileBytes,
      1,
      null,
      'maxIccProfileBytes',
    );
  }
  return switch (ImageFormat.sniff(bytes)) {
    ImageFormat.png => _inspectPng(bytes, maxIccProfileBytes),
    ImageFormat.jpeg => _inspectJpeg(bytes, maxIccProfileBytes),
    ImageFormat.tiff => _inspectTiff(bytes, maxIccProfileBytes),
    ImageFormat.webp => _inspectWebP(bytes, maxIccProfileBytes),
    _ => null,
  };
}

/// Reads PNG header depth and decompresses one bounded `iCCP` chunk.
DecodedImageMetadata _inspectPng(Uint8List bytes, int maxIccProfileBytes) {
  if (bytes.lengthInBytes < 33) {
    throw const ImageCodecException('The PNG header is truncated');
  }
  final ByteData data = ByteData.sublistView(bytes);
  int? width;
  int? height;
  int? bitsPerChannel;
  Uint8List? iccProfile;
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
  );
}

/// Reads JPEG frame fields and reassembles ordered APP2 ICC segments.
DecodedImageMetadata _inspectJpeg(
  Uint8List bytes,
  int maxIccProfileBytes,
) {
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
  );
}

/// Reads baseline TIFF tags without decoding strips.
DecodedImageMetadata _inspectTiff(
  Uint8List bytes,
  int maxIccProfileBytes,
) {
  if (bytes.lengthInBytes < 8) {
    throw const ImageCodecException('The TIFF header is truncated');
  }
  final Endian endian = switch ((bytes[0], bytes[1])) {
    (0x49, 0x49) => Endian.little,
    (0x4d, 0x4d) => Endian.big,
    _ => throw const ImageCodecException('Invalid TIFF byte-order signature'),
  };
  final ByteData data = ByteData.sublistView(bytes);
  if (data.getUint16(2, endian) != 42) {
    throw const ImageCodecException('Invalid TIFF version');
  }
  final int directoryOffset = data.getUint32(4, endian);
  _ensureRange(bytes, directoryOffset, 2);
  final int count = data.getUint16(directoryOffset, endian);
  _ensureRange(bytes, directoryOffset + 2, count * 12 + 4);
  final Map<int, _MetadataTiffField> fields = {};
  for (int index = 0; index < count; index++) {
    final int entry = directoryOffset + 2 + index * 12;
    final int tag = data.getUint16(entry, endian);
    final int type = data.getUint16(entry + 2, endian);
    final int valueCount = data.getUint32(entry + 4, endian);
    final int? typeSize = _tiffTypeSizes[type];
    if (typeSize == null || valueCount > bytes.lengthInBytes) {
      continue;
    }
    final int byteLength = valueCount * typeSize;
    final int valueOffset = byteLength <= 4 ? entry + 8 : data.getUint32(entry + 8, endian);
    _ensureRange(bytes, valueOffset, byteLength);
    fields[tag] = _MetadataTiffField(
      bytes: bytes,
      data: data,
      endian: endian,
      type: type,
      count: valueCount,
      offset: valueOffset,
      byteLength: byteLength,
    );
  }
  final int width = _requiredTiffScalar(fields, 256);
  final int height = _requiredTiffScalar(fields, 257);
  final _MetadataTiffField? depthField = fields[258];
  if (depthField != null && depthField.count > 5) {
    throw const ImageCodecException('Invalid TIFF sample count');
  }
  final List<int> depths = _tiffUnsignedValues(depthField) ?? const [1];
  if (depths.isEmpty || depths.any((depth) => depth != depths.first)) {
    throw const ImageCodecException(
      'TIFF samples of mixed widths are not supported',
    );
  }
  final int photometric = _requiredTiffScalar(fields, 262);
  final _MetadataTiffField? profileField = fields[34675];
  Uint8List? iccProfile;
  if (profileField != null) {
    if (profileField.byteLength > maxIccProfileBytes) {
      throw const ImageCodecException(
        'The TIFF ICC profile exceeds the configured limit',
      );
    }
    iccProfile = Uint8List.fromList(
      Uint8List.sublistView(
        bytes,
        profileField.offset,
        profileField.offset + profileField.byteLength,
      ),
    );
  }
  return DecodedImageMetadata(
    width: width,
    height: height,
    bitsPerChannel: depths.first,
    colorModel: photometric == 5 ? DecodedColorModel.cmyk : DecodedColorModel.rgb,
    iccProfile: iccProfile,
  );
}

/// Reads WebP canvas dimensions and a top-level `ICCP` chunk.
DecodedImageMetadata _inspectWebP(
  Uint8List bytes,
  int maxIccProfileBytes,
) {
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
  );
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

/// TIFF field byte sizes indexed by field type.
const Map<int, int> _tiffTypeSizes = {
  1: 1,
  2: 1,
  3: 2,
  4: 4,
  5: 8,
  6: 1,
  7: 1,
  8: 2,
  9: 4,
  10: 8,
  11: 4,
  12: 8,
};

/// Returns unsigned integer values from one compatible TIFF field.
List<int>? _tiffUnsignedValues(_MetadataTiffField? field) {
  if (field == null) {
    return null;
  }
  if (field.type != 1 && field.type != 3 && field.type != 4) {
    throw ImageCodecException(
      'Unsupported integer TIFF field type: ${field.type}',
    );
  }
  return List<int>.generate(
    field.count,
    field.unsignedAt,
    growable: false,
  );
}

/// Reads one required TIFF scalar.
int _requiredTiffScalar(Map<int, _MetadataTiffField> fields, int tag) {
  final _MetadataTiffField? field = fields[tag];
  if (field == null || field.count < 1) {
    throw ImageCodecException('Required TIFF tag $tag is missing');
  }
  if (field.type != 1 && field.type != 3 && field.type != 4) {
    throw ImageCodecException(
      'Unsupported integer TIFF field type: ${field.type}',
    );
  }
  return field.unsignedAt(0);
}

/// Ensures an encoded byte range lies inside its container.
void _ensureRange(Uint8List bytes, int offset, int length) {
  if (offset < 0 || length < 0 || offset > bytes.lengthInBytes - length) {
    throw const ImageCodecException(
      'An image metadata offset points outside the encoded data',
    );
  }
}

/// Compares one byte range with an ASCII literal.
bool _matchesAscii(Uint8List bytes, int offset, String value) {
  if (offset < 0 || offset > bytes.lengthInBytes - value.length) {
    return false;
  }
  for (int index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) {
      return false;
    }
  }
  return true;
}

/// Reads one unsigned little-endian twenty-four-bit integer.
int _littleUint24(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

/// Reads one unsigned little-endian thirty-two-bit integer.
int _littleUint32(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);

/// Stores one bounded TIFF directory field used during inspection.
final class _MetadataTiffField {
  /// Complete encoded image bytes.
  final Uint8List bytes;

  /// Typed view over [bytes].
  final ByteData data;

  /// Integer byte order.
  final Endian endian;

  /// TIFF field type.
  final int type;

  /// Number of typed values.
  final int count;

  /// Absolute offset of the field payload.
  final int offset;

  /// Total field payload length.
  final int byteLength;

  /// Creates one already bounds-checked TIFF field.
  const _MetadataTiffField({
    required this.bytes,
    required this.data,
    required this.endian,
    required this.type,
    required this.count,
    required this.offset,
    required this.byteLength,
  });

  /// Reads one unsigned integer value.
  int unsignedAt(int index) => switch (type) {
    1 => bytes[offset + index],
    3 => data.getUint16(offset + index * 2, endian),
    4 => data.getUint32(offset + index * 4, endian),
    _ => throw ImageCodecException(
      'TIFF field type $type is not an unsigned integer',
    ),
  };
}
