import 'dart:typed_data';

import 'package:imcodec/src/image_codec_exception.dart';

/// Reads bounded integer values from an encoded image buffer.
final class InputBuffer {
  /// Encoded bytes being read.
  final Uint8List bytes;

  /// Current byte offset.
  int position = 0;

  /// Typed view used for endian-aware integer reads.
  final ByteData _data;

  /// Creates a reader positioned at the beginning of [bytes].
  InputBuffer(this.bytes) : _data = ByteData.sublistView(bytes);

  /// Number of unread bytes.
  int get remaining => bytes.length - position;

  /// Moves to an absolute [offset].
  void seek(int offset) {
    if (offset < 0 || offset > bytes.length) {
      throw const ImageCodecException('An image offset points outside the encoded data');
    }
    position = offset;
  }

  /// Skips [length] bytes.
  void skip(int length) {
    ensure(length);
    position += length;
  }

  /// Ensures that [length] bytes remain available.
  void ensure(int length) {
    if (length < 0 || length > remaining) {
      throw const ImageCodecException('The encoded image is truncated');
    }
  }

  /// Reads one unsigned byte.
  int readUint8() {
    ensure(1);
    return bytes[position++];
  }

  /// Reads a 16-bit unsigned integer.
  int readUint16({Endian endian = Endian.little}) {
    ensure(2);
    final int value = _data.getUint16(position, endian);
    position += 2;
    return value;
  }

  /// Reads a 32-bit unsigned integer.
  int readUint32({Endian endian = Endian.little}) {
    ensure(4);
    final int value = _data.getUint32(position, endian);
    position += 4;
    return value;
  }

  /// Reads a 32-bit signed integer.
  int readInt32({Endian endian = Endian.little}) {
    ensure(4);
    final int value = _data.getInt32(position, endian);
    position += 4;
    return value;
  }

  /// Reads a byte slice and advances past it.
  Uint8List readBytes(int length) {
    ensure(length);
    final Uint8List result = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    return result;
  }
}
