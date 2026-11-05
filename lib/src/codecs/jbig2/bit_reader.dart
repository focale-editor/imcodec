part of '../jbig2.dart';

/// Bounded byte view shared by segment bit readers and the MMR decoder.
final class _Jbig2ByteReader {
  /// Reader backed by the package's validated byte buffer.
  final InputBuffer _input;

  /// Creates a reader over [bytes] without copying them.
  _Jbig2ByteReader({required Uint8List bytes}) : _input = InputBuffer(bytes);

  /// Length of this view in bytes.
  int get length => _input.bytes.length;

  /// Current byte position within this view.
  int get position => _input.position;

  /// Returns the next byte, or the arithmetic coder's end-of-input sentinel.
  int read() => _input.remaining == 0 ? -1 : _input.readUint8();

  /// Looks at the next byte without advancing.
  int peek() => _input.remaining == 0 ? -1 : _input.bytes[position];

  /// Seeks within this bounded view.
  void seek(int position) => _input.seek(position);

  /// Reads up to the size of [target], returning the number of bytes copied.
  int readBuffer(Uint8List target) {
    final int count = math.min(target.length, _input.remaining);
    target.setRange(0, count, _input.readBytes(count));
    return count;
  }

  /// Fills [target], rejecting truncated input.
  void readFully(Uint8List target) => target.setAll(0, _input.readBytes(target.length));

  /// Creates an independent cursor limited to a segment's declared bytes.
  _Jbig2ByteReader createView(int offset, int length) {
    if (offset < 0 || length < 0 || offset > this.length - length) {
      throw const ImageCodecException('JBIG2 segment extends beyond its input');
    }
    return _Jbig2ByteReader(bytes: Uint8List.sublistView(_input.bytes, offset, offset + length));
  }
}

/// Reads MSB-first bits while preserving arithmetic coder byte access.
final class _Jbig2BitReader {
  /// Underlying bounded byte source.
  final _Jbig2ByteReader wrappedStream;

  /// Start of this segment in the underlying source.
  final int offset;

  /// Length of the segment in bytes.
  final int length;

  /// Current byte offset within the segment.
  int _position = 0;

  /// Number of bits already consumed from the current byte.
  int _bitOffset = 0;

  /// Creates a validated segment view.
  _Jbig2BitReader({required this.wrappedStream, required this.offset, required this.length}) {
    if (offset < 0 || length < 0 || offset > wrappedStream.length - length) {
      throw const ImageCodecException('JBIG2 bit stream extends beyond its input');
    }
  }

  /// Reads a byte, returning -1 only at the segment boundary.
  int read() {
    if (_position >= length) {
      return -1;
    }
    wrappedStream.seek(offset + _position++);
    _bitOffset = 0;
    return wrappedStream.read();
  }

  /// Reads one bit, rejecting truncated headers and Huffman codewords.
  int readBit() {
    if (_position >= length) {
      throw const ImageCodecException('Truncated JBIG2 bit stream');
    }
    wrappedStream.seek(offset + _position);
    final int result = (wrappedStream.peek() >> (7 - _bitOffset)) & 1;
    if (++_bitOffset == 8) {
      _bitOffset = 0;
      _position++;
    }
    return result;
  }

  /// Reads an unsigned value of at most 32 bits, including on the Web.
  int readBits(int count) {
    if (count < 0 || count > 32) {
      throw RangeError.range(count, 0, 32, 'count');
    }
    int value = 0;
    for (int index = 0; index < count; index++) {
      value = value * 2 + readBit();
    }
    return value;
  }

  /// Seeks to a byte boundary inside this segment.
  void seek(int position) {
    if (position < 0 || position > length) {
      throw const ImageCodecException('Invalid JBIG2 stream offset');
    }
    _position = position;
    _bitOffset = 0;
  }

  /// Returns the current byte offset.
  int getStreamPosition() => _position;

  /// Returns the number of bits consumed in the current byte.
  int getBitOffset() => _bitOffset;

  /// Aligns the cursor to the next byte.
  void skipBits() {
    if (_bitOffset != 0) {
      _bitOffset = 0;
      _position++;
    }
  }

  /// Returns the number of remaining bytes.
  int available() => length - _position;

  /// Reads a complete byte sequence from this segment.
  void readFully(Uint8List target) {
    if (target.length > available()) {
      throw const ImageCodecException('Truncated JBIG2 segment');
    }
    wrappedStream.seek(offset + _position);
    wrappedStream.readFully(target);
    _position += target.length;
    _bitOffset = 0;
  }
}

/// Sends decoder diagnostics to Dart DevTools.
abstract final class _Jbig2Log {
  /// Records a recoverable informational message.
  static void info(String message) => developer.log(message, name: 'imcodec.jbig2');
}
