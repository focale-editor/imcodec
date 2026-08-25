import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Reads a JPEG XL codestream bit by bit.
///
/// JPEG XL bitstreams are read LSB-first within each byte: the first bit read
/// from a byte is its least significant bit, and the first bit read
/// contributes the least significant bit of the returned value.
///
/// The cache invariant keeps [_cache] strictly below 2^40 (at most 39 live
/// bits), so all arithmetic stays in non-negative Dart ints and never touches
/// the sign bit.
final class BitReader {
  /// Stores the data state used internally by the JPEG XL codec.
  ///
  final Uint8List _data;

  /// Stores the pos state used internally by the JPEG XL codec.
  ///
  int _pos = 0;

  /// Stores the cache state used internally by the JPEG XL codec.
  ///
  int _cache = 0;

  /// Stores the cache bits state used internally by the JPEG XL codec.
  ///
  int _cacheBits = 0;

  /// Creates Bit reader data for JPEG XL processing.
  ///
  BitReader({
    required this._data,
  });

  /// A reader over `data[start..end)` without copying.
  BitReader.view({
    required Uint8List data,
    required int start,
    int? end,
  }) : this(data: Uint8List.sublistView(data, start, end));

  /// Total number of bits consumed so far.
  int get bitsRead => (_pos << 3) - _cacheBits;

  /// Whether every bit of the input has been consumed.
  bool get atEnd => _cacheBits == 0 && _pos >= _data.length;

  /// Whether the read position is on a byte boundary.
  bool get isAligned => _cacheBits & 7 == 0;

  /// Byte offset of the read position. Only valid when [isAligned].
  int get bytePosition {
    assert(isAligned, 'The reader must be byte-aligned.');
    return _pos - (_cacheBits >> 3);
  }

  /// Bytes remaining from the current (aligned) position, as a no-copy view.
  Uint8List remainingBytes() {
    assert(isAligned, 'The reader must be byte-aligned.');
    return Uint8List.sublistView(_data, bytePosition);
  }

  /// Reads `bits` bits (0–32) and returns them as an unsigned value.
  @pragma('vm:prefer-inline')
  int readBits(int bits) {
    assert(bits >= 0 && bits <= 32, 'The bit count must be between 0 and 32.');
    if (bits == 0) {
      return 0;
    }
    while (_cacheBits < bits) {
      if (_pos >= _data.length) {
        throw JpegXlTruncatedException(message: 'unable to read $bits bits at bit position $bitsRead');
      }
      // += (not |=): _cacheBits is always < 32 here (the loop can add at
      // most 4 bytes before bits <= 32 stops it), so `1 << _cacheBits` is
      // itself safe, but the ACCUMULATED _cache can exceed 2^32 - and
      // dart2js's `|=` (like all its bitwise ops) truncates through a
      // 32-bit integer regardless of shift amount, silently dropping any
      // high bits already in _cache. Addition doesn't have that limit,
      // and is equivalent here since the new byte's bit range never
      // overlaps what's already in _cache.
      _cache += _data[_pos++] * (1 << _cacheBits);
      _cacheBits += 8;
    }
    // bits == 32 is a real call (ANS state init reads a raw 32-bit word):
    // computing the mask as `(1 << bits) - 1` breaks on dart2js there,
    // since a *computed* `1 << 32` silently gives 0 (not 4294967296), even
    // though the mask value itself is exactly representable.
    final int mask = bits == 32 ? 0xFFFFFFFF : (1 << bits) - 1;
    final int ret = _cache & mask;
    _cache = wideShr(_cache, bits);
    _cacheBits -= bits;
    return ret;
  }

  /// Returns the next `bits` bits without consuming them.
  ///
  /// Bits past the end of the input read as zero (required by prefix-code
  /// lookup near the end of a stream).
  @pragma('vm:prefer-inline')
  int peekBits(int bits) {
    assert(bits >= 0 && bits <= 32, 'The bit count must be between 0 and 32.');
    while (_cacheBits < bits && _pos < _data.length) {
      // += (not |=): _cacheBits is always < 32 here (the loop can add at
      // most 4 bytes before bits <= 32 stops it), so `1 << _cacheBits` is
      // itself safe, but the ACCUMULATED _cache can exceed 2^32 - and
      // dart2js's `|=` (like all its bitwise ops) truncates through a
      // 32-bit integer regardless of shift amount, silently dropping any
      // high bits already in _cache. Addition doesn't have that limit,
      // and is equivalent here since the new byte's bit range never
      // overlaps what's already in _cache.
      _cache += _data[_pos++] * (1 << _cacheBits);
      _cacheBits += 8;
    }
    return _cache & (bits == 32 ? 0xFFFFFFFF : (1 << bits) - 1);
  }

  /// Processes read bool information in a JPEG XL codestream.
  ///
  bool readBool() => readBits(1) != 0;

  /// The spec's `U32(...)` field: a 2-bit selector choosing one of four
  /// (constant, extra-bits) alternatives; value = constant + extra bits.
  int readU32(int c0, int u0, int c1, int u1, int c2, int u2, int c3, int u3) {
    switch (readBits(2)) {
      case 0:
        return c0 + readBits(u0);
      case 1:
        return c1 + readBits(u1);
      case 2:
        return c2 + readBits(u2);
      default:
        return c3 + readBits(u3);
    }
  }

  /// The spec's variable-length `U64()` field.
  int readU64() {
    final int index = readBits(2);
    if (index == 0) {
      return 0;
    }
    if (index == 1) {
      return 1 + readBits(4);
    }
    if (index == 2) {
      return 17 + readBits(8);
    }
    int value = readBits(12);
    var shift = 12;
    while (readBool()) {
      if (shift == 60) {
        value |= wideShl(readBits(4), shift);
        break;
      }
      value |= wideShl(readBits(8), shift);
      shift += 8;
    }
    return value;
  }

  /// A 16-bit IEEE half-precision float. Infinities and NaN are illegal in
  /// JPEG XL headers.
  double readF16() {
    final int bits16 = readBits(16);
    final int mantissa = bits16 & 0x3FF;
    final int exp = (bits16 >> 10) & 0x1F;
    if (exp == 31) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal infinite/NaN float16');
    }
    // Subnormal: m * 2^-24; normal: (m + 1024) * 2^(e - 25).
    final double magnitude = exp == 0 ? mantissa * 5.9604644775390625e-8 : (mantissa + 1024) * _pow2(exp - 25);
    return bits16 & 0x8000 != 0 ? -magnitude : magnitude;
  }

  /// The spec's `Enum()` field; values above 63 are invalid.
  int readEnum() {
    final int constant = readU32(0, 0, 1, 0, 2, 4, 18, 6);
    if (constant > 63) {
      throw const JpegXlInvalidBitstreamException(message: 'enum constant > 63');
    }
    return constant;
  }

  /// Variable-length U8 used by ANS distribution headers.
  int readU8() {
    if (!readBool()) {
      return 0;
    }
    final int n = readBits(3);
    if (n == 0) {
      return 1;
    }
    return readBits(n) + (1 << n);
  }

  /// LEB128-style varint used by the compressed ICC stream.
  int readIccVarint() {
    var value = 0;
    for (var shift = 0; shift < 63; shift += 7) {
      final int b = readBits(8);
      value |= wideShl(b & 127, shift);
      if (b <= 127) {
        break;
      }
    }
    if (value > 0x7FFFFFFF) {
      throw const JpegXlInvalidBitstreamException(message: 'ICC varint overflow');
    }
    return value;
  }

  /// Consumes bits up to the next byte boundary, which must all be zero.
  ///
  /// Bits are only ever consumed from the cache, so `_cacheBits % 8` is
  /// always the exact distance to the next byte boundary.
  void zeroPadToByte() {
    final int remaining = _cacheBits % 8;
    if (remaining > 0 && readBits(remaining) != 0) {
      throw const JpegXlInvalidBitstreamException(message: 'nonzero zero-padding-to-byte');
    }
  }

  /// Skips `bits` bits (any count ≥ 0).
  void skipBits(int bitCount) {
    int bits = bitCount;
    assert(bits >= 0, 'The skipped bit count cannot be negative.');
    if (bits <= _cacheBits) {
      _cache = wideShr(_cache, bits);
      _cacheBits -= bits;
      return;
    }
    bits -= _cacheBits;
    _cache = 0;
    _cacheBits = 0;
    final int bytes = bits >> 3;
    if (_pos + bytes > _data.length) {
      throw JpegXlTruncatedException(message: 'unable to skip $bits bits');
    }
    _pos += bytes;
    readBits(bits & 7);
  }
}

/// Processes the pow2 data used by the JPEG XL codec.
///
double _pow2(int e) {
  // e is in [-25, 6] for f16; direct ldexp.
  var v = 1.0;
  var n = e;
  while (n > 0) {
    v *= 2.0;
    n--;
  }
  while (n < 0) {
    v /= 2.0;
    n++;
  }
  return v;
}
