part of '../jbig2.dart';

/// Maps standalone and PDF segment streams without decoding their bitmaps.
final class _Jbig2Document {
  /// Pages in numerical association order.
  final Map<int, _Jbig2Page> pages = SplayTreeMap();

  /// Global segments available to every page.
  final Map<int, _Jbig2Segment> globals;

  /// Maximum number of segments accepted by this document.
  final int maxSegments;

  /// Creates a segment map and validates all lengths and references.
  _Jbig2Document({required Uint8List bytes, required this.maxSegments, Map<int, _Jbig2Segment>? globals}) : globals = {...?globals} {
    final _Jbig2ByteReader source = _Jbig2ByteReader(bytes: bytes);
    final _Jbig2BitReader reader = _Jbig2BitReader(wrappedStream: source, offset: 0, length: bytes.length);
    bool sequential = true;
    if (ImageFormat.jbig2.matches(bytes)) {
      reader.seek(8);
      final int flags = reader.readBits(8);
      if ((flags & 0xf8) != 0) {
        throw const ImageCodecException('Invalid JBIG2 file flags');
      }
      sequential = (flags & 1) != 0;
      if ((flags & 2) == 0) {
        reader.readBits(32);
      }
    }
    final List<_Jbig2Segment> segments = [];
    final Set<(int, int)> numbers = {for (final int number in this.globals.keys) (0, number)};
    bool ended = false;
    while (reader.available() != 0) {
      if (segments.length >= maxSegments) {
        throw const ImageCodecException('JBIG2 exceeds the segment limit');
      }
      final _Jbig2Segment segment = _Jbig2Segment(document: this, reader: reader);
      if (!numbers.add((segment.pageAssociation, segment.segmentNr))) {
        throw const ImageCodecException('Duplicate JBIG2 segment number');
      }
      segments.add(segment);
      if (segment.pageAssociation == 0) {
        this.globals[segment.segmentNr] = segment;
      } else {
        final _Jbig2Page page = pages.putIfAbsent(segment.pageAssociation, () => _Jbig2Page(document: this, pageNumber: segment.pageAssociation));
        page.add(segment);
      }
      if (sequential) {
        segment.setDataOffset(reader.getStreamPosition());
        reader.seek(segment.segmentDataStartOffset + segment.segmentDataLength);
      }
      if (segment.segmentType == 51) {
        ended = true;
        break;
      }
    }
    if (ImageFormat.jbig2.matches(bytes) && !ended) {
      throw const ImageCodecException('Standalone JBIG2 file has no end-of-file segment');
    }
    if (!sequential) {
      if (!ended) {
        throw const ImageCodecException('JBIG2 random-access header has no end-of-file segment');
      }
      int offset = reader.getStreamPosition();
      for (final _Jbig2Segment segment in segments) {
        segment.setDataOffset(offset);
        offset += segment.segmentDataLength;
      }
      reader.seek(offset);
    }
    if (reader.available() != 0) {
      throw const ImageCodecException('Trailing bytes after JBIG2 end-of-file');
    }
    for (final _Jbig2Segment segment in segments) {
      segment.resolveReferences();
    }
  }

  /// Finds a shared dictionary or intermediate region.
  _Jbig2Segment? getGlobalSegment(int number) => globals[number];
}
