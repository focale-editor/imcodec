part of '../jbig2.dart';

/// One segment header and its lazily decoded, bounded payload.
final class _Jbig2Segment {
  /// Owning document used to resolve page and global references.
  final _Jbig2Document document;

  /// Source containing this segment.
  final _Jbig2BitReader reader;

  /// Segment sequence number.
  late final int segmentNr;

  /// T.88 segment type.
  late final int segmentType;

  /// Page association, with zero denoting globals.
  late final int pageAssociation;

  /// Resolved references in header order.
  final List<_Jbig2Segment> rtSegments = [];

  /// Referenced segment sequence numbers.
  final List<int> _references = [];

  /// Number of payload bytes.
  late int segmentDataLength;

  /// Payload start in the complete input.
  int segmentDataStartOffset = 0;

  /// Whether the header declares an unknown generic-region length.
  bool hasUnknownDataLength = false;

  /// Actual row count from an unknown-length generic-region trailer.
  int unknownLengthRowCount = -1;

  /// Cached decoded payload.
  _Jbig2SegmentData? _data;

  /// Prevents recursive segment dependencies from re-entering a decoder.
  bool _decoding = false;

  /// Reads and validates one segment header.
  _Jbig2Segment({required this.document, required this.reader}) {
    segmentNr = reader.readBits(32);
    final int flags = reader.readBits(8);
    segmentType = flags & 63;
    final int referenceFlags = reader.readBits(8);
    int count = referenceFlags >> 5;
    if (count == 5 || count == 6) {
      throw const ImageCodecException('Invalid JBIG2 reference count');
    }
    if (count == 7) {
      count = (referenceFlags & 31) * 0x1000000 + reader.readBits(24);
      if (count > document.maxSegments || (count + 8) ~/ 8 > reader.available()) {
        throw const ImageCodecException('JBIG2 reference count exceeds the input or segment limit');
      }
      reader.seek(reader.getStreamPosition() + (count + 8) ~/ 8);
    }
    final int referenceBits = segmentNr <= 256 ? 8 : (segmentNr <= 65536 ? 16 : 32);
    if (count > reader.available() ~/ (referenceBits ~/ 8)) {
      throw const ImageCodecException('Truncated JBIG2 references');
    }
    for (int index = 0; index < count; index++) {
      final int number = reader.readBits(referenceBits);
      if (number >= segmentNr) {
        throw const ImageCodecException('JBIG2 references must precede their segment');
      }
      _references.add(number);
    }
    pageAssociation = reader.readBits((flags & 64) == 0 ? 8 : 32);
    segmentDataLength = reader.readBits(32);
    if (![0, 4, 6, 7, 16, 20, 22, 23, 36, 38, 39, 40, 42, 43, 48, 49, 50, 51, 52, 53, 62].contains(segmentType)) {
      throw ImageCodecException('Unsupported JBIG2 segment type $segmentType');
    }
  }

  /// Bounds the payload and resolves the generic-region unknown-length trailer.
  void setDataOffset(int offset) {
    segmentDataStartOffset = offset;
    if (segmentDataLength == 0xffffffff) {
      if (segmentType != 38 && segmentType != 39) {
        throw const ImageCodecException('Unknown JBIG2 length is only valid for immediate generic regions');
      }
      final Uint8List bytes = reader.wrappedStream._input.bytes;
      if (offset > bytes.length - 18) {
        throw const ImageCodecException('Truncated JBIG2 generic region');
      }
      final bool mmr = (bytes[offset + 17] & 1) != 0;
      final int first = mmr ? 0 : 255;
      final int second = mmr ? 0 : 172;
      int end = offset + 18;
      while (end < bytes.length - 5 && (bytes[end] != first || bytes[end + 1] != second)) {
        end++;
      }
      if (end >= bytes.length - 5) {
        throw const ImageCodecException('JBIG2 generic region has no terminating marker');
      }
      hasUnknownDataLength = true;
      unknownLengthRowCount = ByteData.sublistView(bytes).getUint32(end + 2);
      segmentDataLength = end + 6 - offset;
    }
    if (offset < 0 || segmentDataLength > reader.length - offset) {
      throw const ImageCodecException('Truncated JBIG2 segment payload');
    }
    if (segmentType == 62) {
      final int extension = getDataInputStream().readBits(32);
      if (extension >= 0x80000000) {
        throw ImageCodecException('Unsupported required JBIG2 extension $extension');
      }
    }
  }

  /// Resolves references after both sequential and random-access headers exist.
  void resolveReferences() {
    for (final int number in _references) {
      final _Jbig2Segment? segment = document.pages[pageAssociation]?.getSegment(number) ?? document.getGlobalSegment(number);
      if (segment == null) {
        throw ImageCodecException('Missing JBIG2 referenced segment $number');
      }
      rtSegments.add(segment);
    }
  }

  /// Returns a reader restricted to this segment's payload.
  _Jbig2BitReader getDataInputStream() => _Jbig2BitReader(wrappedStream: reader.wrappedStream, offset: segmentDataStartOffset, length: segmentDataLength);

  /// Decodes a supported segment once, preserving its data for references.
  _Jbig2SegmentData? getSegmentData() {
    if (_data != null) {
      return _data;
    }
    if (_decoding) {
      throw const ImageCodecException('Cyclic JBIG2 segment references');
    }
    final _Jbig2SegmentData? data = switch (segmentType) {
      0 => _Jbig2SymbolDictionary(),
      4 || 6 || 7 => _Jbig2TextRegion(),
      16 => _Jbig2PatternDictionary(),
      20 || 22 || 23 => _Jbig2HalftoneRegion(),
      36 || 38 || 39 => _Jbig2GenericRegion(),
      40 || 42 || 43 => _Jbig2GenericRefinementRegion(),
      48 => _Jbig2PageInformation(),
      50 => _Jbig2EndOfStripe(),
      53 => _Jbig2Table(),
      _ => null,
    };
    if (data == null) {
      return null;
    }
    _decoding = true;
    try {
      data.init(this, getDataInputStream());
      return _data = data;
    } finally {
      _decoding = false;
    }
  }

  /// Releases decoded segment data after page composition.
  void cleanSegmentData() => _data = null;
}
