part of '../webp.dart';

/// Provides the bounded pointer-like access required by VP8 algorithms.
final class _WebPBuffer {
  /// Underlying typed or untyped integer storage.
  List<int> buffer;

  /// Initial absolute offset used for relative positions.
  final int start;

  /// Exclusive absolute end of the bounded view.
  final int end;

  /// Whether multi-byte reads use big-endian order.
  final bool bigEndian;

  /// Current absolute offset.
  int offset;

  /// Creates a bounded view over [data].
  _WebPBuffer({
    required List<int> data,
    this.bigEndian = false,
    this.offset = 0,
    int? length,
  }) : buffer = data,
       start = offset,
       end = math.min(data.length, offset + (length ?? data.length - offset));

  /// Creates a view relative to another buffer's current position.
  _WebPBuffer.from({
    required _WebPBuffer source,
    int offset = 0,
    int? length,
  }) : buffer = source.buffer,
       start = source.start,
       end = math.min(source.end, source.offset + offset + (length ?? source.end - source.offset - offset)),
       bigEndian = source.bigEndian,
       offset = source.offset + offset;

  /// Current position relative to [start].
  int get position => offset - start;

  /// Number of unread values in this view.
  int get length => end - offset;

  /// Whether the current position reached the end of the view.
  bool get isEOS => offset >= end;

  /// Reads a value relative to the current position.
  int operator [](int index) => buffer[offset + index];

  /// Writes a value relative to the current position.
  void operator []=(int index, int value) => buffer[offset + index] = value;

  /// Copies [length] values from [other] into this buffer.
  void memcpy(int destinationOffset, int length, Object other, [int sourceOffset = 0]) {
    final List<int> source = other is _WebPBuffer ? other.buffer : other as List<int>;
    final int sourceStart = other is _WebPBuffer ? other.offset + sourceOffset : sourceOffset;
    buffer.setRange(offset + destinationOffset, offset + destinationOffset + length, source, sourceStart);
  }

  /// Fills a range relative to the current position.
  void memset(int destinationOffset, int length, int value) => buffer.fillRange(offset + destinationOffset, offset + destinationOffset + length, value);

  /// Returns a bounded subview without advancing this buffer.
  _WebPBuffer subset(int count, {int? position, int offset = 0}) {
    final int viewOffset = (position == null ? this.offset : start + position) + offset;
    return _WebPBuffer(data: buffer, bigEndian: bigEndian, offset: viewOffset, length: count);
  }

  /// Returns the next [count] values without advancing this buffer.
  _WebPBuffer peekBytes(int count, [int offset = 0]) => subset(count, offset: offset);

  /// Advances by [count] values.
  void skip(int count) => offset += count;

  /// Reads one value.
  int readByte() {
    if (isEOS) {
      throw const ImageCodecException('The WebP data is truncated');
    }
    return buffer[offset++];
  }

  /// Reads a 16-bit integer.
  int readUint16() {
    final int first = readByte() & 0xff;
    final int second = readByte() & 0xff;
    return bigEndian ? (first << 8) | second : first | (second << 8);
  }

  /// Reads a 24-bit integer.
  int readUint24() {
    final int first = readByte() & 0xff;
    final int second = readByte() & 0xff;
    final int third = readByte() & 0xff;
    return bigEndian ? (first << 16) | (second << 8) | third : first | (second << 8) | (third << 16);
  }

  /// Reads a 32-bit integer.
  int readUint32() {
    final int first = readByte() & 0xff;
    final int second = readByte() & 0xff;
    final int third = readByte() & 0xff;
    final int fourth = readByte() & 0xff;
    return bigEndian ? (first << 24) | (second << 16) | (third << 8) | fourth : first | (second << 8) | (third << 16) | (fourth << 24);
  }

  /// Reads a bounded subview and advances past it.
  _WebPBuffer readBytes(int count) {
    final _WebPBuffer result = subset(count);
    skip(count);
    return result;
  }

  /// Returns an unsigned byte view over the remaining storage.
  Uint8List toUint8List([int relativeOffset = 0, int? requestedLength]) {
    final int viewLength = requestedLength ?? length - relativeOffset;
    if (buffer case final Uint8List bytes) {
      return Uint8List.view(bytes.buffer, bytes.offsetInBytes + offset + relativeOffset, viewLength);
    }
    return Uint8List.fromList(buffer.sublist(offset + relativeOffset, offset + relativeOffset + viewLength));
  }

  /// Returns a 32-bit view over the remaining byte storage.
  Uint32List toUint32List([int relativeOffset = 0]) {
    if (buffer case final Uint8List bytes) {
      return Uint32List.view(bytes.buffer, bytes.offsetInBytes + offset + relativeOffset);
    }
    if (buffer case final Uint32List values) {
      return Uint32List.sublistView(values, offset + relativeOffset);
    }
    throw const ImageCodecException('WebP requested a 32-bit view of incompatible storage');
  }
}
