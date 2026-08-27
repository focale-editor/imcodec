part of '../jpeg.dart';

/// Reads bounded big-endian values from JPEG segments and entropy data.
final class _JpegInput {
  /// Complete encoded byte buffer.
  final Uint8List bytes;

  /// First byte accessible through this view.
  final int start;

  /// Exclusive end of this view.
  final int end;

  /// Whether multi-byte integers use big-endian order.
  final bool bigEndian;

  /// Current absolute position in [bytes].
  int _offset;

  /// Creates a bounded view over [bytes].
  _JpegInput({
    required this.bytes,
    this.bigEndian = true,
    int offset = 0,
    int? length,
  }) : start = offset,
       end = math.min(bytes.length, offset + (length ?? bytes.length - offset)),
       _offset = offset {
    if (offset < 0 || offset > bytes.length || (length != null && length < 0)) {
      throw const ImageCodecException('A JPEG segment points outside the encoded data');
    }
  }

  /// Current absolute byte position.
  int get offset => _offset;

  /// Moves the current absolute byte position within this view.
  set offset(int value) {
    if (value < start || value > end) {
      throw const ImageCodecException('A JPEG segment points outside the encoded data');
    }
    _offset = value;
  }

  /// Current position relative to [start].
  int get position => _offset - start;

  /// Number of unread bytes in this view.
  int get length => end - _offset;

  /// Whether no unread byte remains.
  bool get isEOS => _offset >= end;

  /// Reads a byte relative to the current position without advancing.
  int operator [](int index) {
    final int absoluteIndex = _offset + index;
    if (absoluteIndex < start || absoluteIndex >= end) {
      throw const ImageCodecException('The JPEG data is truncated');
    }
    return bytes[absoluteIndex];
  }

  /// Returns a bounded view without advancing.
  _JpegInput subset(int count, {int? position, int offset = 0}) {
    final int viewStart = (position == null ? _offset : start + position) + offset;
    if (count < 0 || viewStart < start || count > end - viewStart) {
      throw const ImageCodecException('The JPEG segment is truncated');
    }
    return _JpegInput(bytes: bytes, bigEndian: bigEndian, offset: viewStart, length: count);
  }

  /// Returns the next [count] bytes without advancing.
  _JpegInput peekBytes(int count, [int offset = 0]) => subset(count, offset: offset);

  /// Advances by [count] bytes.
  void skip(int count) => offset = _offset + count;

  /// Reads one unsigned byte.
  int readByte() {
    if (isEOS) {
      throw const ImageCodecException('The JPEG data is truncated');
    }
    return bytes[_offset++];
  }

  /// Reads two bytes using the configured byte order.
  int readUint16() {
    final int first = readByte();
    final int second = readByte();
    return bigEndian ? (first << 8) | second : (second << 8) | first;
  }

  /// Reads four bytes using the configured byte order.
  int readUint32() {
    final int first = readByte();
    final int second = readByte();
    final int third = readByte();
    final int fourth = readByte();
    return bigEndian ? (first << 24) | (second << 16) | (third << 8) | fourth : (fourth << 24) | (third << 16) | (second << 8) | first;
  }

  /// Reads a new bounded view and advances past it.
  _JpegInput readBytes(int count) {
    final _JpegInput result = subset(count);
    skip(count);
    return result;
  }

  /// Copies the unread portion of this view to an unsigned byte list.
  Uint8List toUint8List() => Uint8List.sublistView(bytes, _offset, end);
}
