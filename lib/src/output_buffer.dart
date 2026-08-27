import 'dart:typed_data';

/// Accumulates endian-aware primitive values in a growable byte buffer.
final class OutputBuffer {
  /// Number of bytes currently written.
  int length;

  /// Whether multi-byte values are written most-significant byte first.
  bool bigEndian;

  /// Storage block used when growing an empty buffer.
  static const int _blockSize = 0x2000;

  /// Writable storage backing this output.
  Uint8List _buffer;

  /// Creates a byte buffer for writing.
  OutputBuffer({int? size = _blockSize, this.bigEndian = false}) : _buffer = Uint8List(size ?? _blockSize), length = 0;

  /// Discards written bytes while retaining allocated storage.
  void rewind() {
    length = 0;
  }

  /// Returns a view of the bytes written so far.
  /// The result aliases this buffer, so copy it before writing again.
  Uint8List getBytes() => Uint8List.view(_buffer.buffer, 0, length);

  /// Returns the written bytes and leaves this buffer empty.
  /// The result never aliases storage that later writes can reach.
  Uint8List takeBytes() {
    final Uint8List result = Uint8List.view(_buffer.buffer, 0, length);
    _buffer = Uint8List(_blockSize);
    length = 0;
    return result;
  }

  /// Clears the buffer.
  void clear() {
    _buffer = Uint8List(_blockSize);
    length = 0;
  }

  /// Writes a byte to the end of the buffer.
  void writeByte(int value) {
    if (length == _buffer.length) {
      _expandBuffer();
    }
    _buffer[length++] = value & 0xff;
  }

  /// Writes a set of bytes to the end of the buffer.
  void writeBytes(List<int> bytes, [int? len]) {
    final int count = len ?? bytes.length;
    if (length + count > _buffer.length) {
      _expandBuffer(count);
    }
    _buffer.setRange(length, length + count, bytes);
    length += count;
  }

  /// Writes a 16-bit word to the end of the buffer.
  void writeUint16(int value) {
    if (bigEndian) {
      writeByte((value >> 8) & 0xff);
      writeByte(value & 0xff);
      return;
    }
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  /// Writes a 32-bit word to the end of the buffer.
  void writeUint32(int value) {
    if (bigEndian) {
      writeByte((value >> 24) & 0xff);
      writeByte((value >> 16) & 0xff);
      writeByte((value >> 8) & 0xff);
      writeByte(value & 0xff);
      return;
    }
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
  }

  /// Writes a 32-bit floating-point value.
  void writeFloat32(double value) {
    final fb = Float32List(1);
    fb[0] = value;
    final b = Uint8List.view(fb.buffer);
    if (bigEndian) {
      writeByte(b[3]);
      writeByte(b[2]);
      writeByte(b[1]);
      writeByte(b[0]);
      return;
    }
    writeByte(b[0]);
    writeByte(b[1]);
    writeByte(b[2]);
    writeByte(b[3]);
  }

  /// Writes a 64-bit floating-point value.
  void writeFloat64(double value) {
    final fb = Float64List(1);
    fb[0] = value;
    final b = Uint8List.view(fb.buffer);
    if (bigEndian) {
      writeByte(b[7]);
      writeByte(b[6]);
      writeByte(b[5]);
      writeByte(b[4]);
      writeByte(b[3]);
      writeByte(b[2]);
      writeByte(b[1]);
      writeByte(b[0]);
      return;
    }
    writeByte(b[0]);
    writeByte(b[1]);
    writeByte(b[2]);
    writeByte(b[3]);
    writeByte(b[4]);
    writeByte(b[5]);
    writeByte(b[6]);
    writeByte(b[7]);
  }

  /// Returns the subset of the buffer in the range \[start, end\].
  /// If [start] or [end] are < 0 then it is relative to the end of the buffer.
  /// If [end] is not specified (or null), then it is the end of the buffer.
  /// This is equivalent to the python list range operator.
  List<int> subset(int start, [int? end]) {
    final int resolvedStart = start < 0 ? length + start : start;
    final int resolvedEnd = end == null
        ? length
        : end < 0
        ? length + end
        : end;
    return Uint8List.view(_buffer.buffer, resolvedStart, resolvedEnd - resolvedStart);
  }

  /// Grows the buffer so that [required] more bytes fit.
  /// Capacity always at least doubles, which keeps repeated writes amortized
  /// to linear time instead of reallocating on every call.
  void _expandBuffer([int required = 0]) {
    int capacity = _buffer.isEmpty ? _blockSize : _buffer.length * 2;
    final int needed = length + required;
    while (capacity < needed) {
      capacity *= 2;
    }
    _buffer = Uint8List(capacity)..setRange(0, length, _buffer);
  }
}
