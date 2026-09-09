part of 'image_format.dart';

/// Tagged Image File Format format.
final class _TiffFormat extends ImageFormat with InspectableFormat {
  /// TIFF field byte sizes indexed by field type.
  static const Map<int, int> _tiffTypeSizes = {
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

  /// Creates a Tagged Image File Format format.
  const _TiffFormat() : super(name: 'tiff');

  @override
  bool matches(Uint8List bytes) =>
      bytes.length >= 4 && ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2a && bytes[3] == 0x00) || (bytes[0] == 0x4d && bytes[1] == 0x4d && bytes[2] == 0x00 && bytes[3] == 0x2a));

  @override
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes) {
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
    final _MetadataTiffField? iptcField = fields[33723];
    final _MetadataTiffField? xmpField = fields[700];
    return DecodedImageMetadata(
      width: width,
      height: height,
      bitsPerChannel: depths.first,
      colorModel: photometric == 5 ? DecodedColorModel.cmyk : DecodedColorModel.rgb,
      iccProfile: iccProfile,
      iptcMetadata: iptcField == null
          ? null
          : _boundedPacket(
              bytes,
              iptcField.offset,
              iptcField.byteLength,
              maximumBytes: maxDescriptiveMetadataBytes,
              label: 'TIFF IPTC',
            ),
      xmpMetadata: xmpField == null
          ? null
          : _boundedPacket(
              bytes,
              xmpField.offset,
              xmpField.byteLength,
              maximumBytes: maxDescriptiveMetadataBytes,
              label: 'TIFF XMP',
            ),
    );
  }

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
}

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
