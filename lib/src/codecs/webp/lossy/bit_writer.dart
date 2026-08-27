part of '../../webp.dart';

/// Writes arithmetic-coded bits into a lossy VP8 partition.
///
/// This is the exact counterpart of [_Vp8BitReader]: every value written here
/// is read back by the matching read call, in the same order.
final class _Vp8BitWriter {
  /// Number of bits to shift the range by, indexed by the current range.
  ///
  /// Shifting by this amount brings the range back into the 128 through 255
  /// interval the coder works in.
  static final Uint8List _normalizationShifts = Uint8List.fromList(<int>[
    for (int range = 0; range < 128; ++range) 7 - _highestBit(range + 1),
  ]);

  /// Range value after normalization, indexed by the range before it.
  static final Uint8List _normalizedRanges = Uint8List.fromList(<int>[
    for (int range = 0; range < 128; ++range) ((range + 1) << _normalizationShifts[range]) - 1,
  ]);

  /// Bytes written so far, including the pending run of carry-sensitive bytes.
  Uint8List _bytes = Uint8List(4096);

  /// Number of bytes in [_bytes] that hold final output.
  int _position = 0;

  /// Current arithmetic range, always between 127 and 254.
  int _range = 254;

  /// Bits accumulated but not yet split into bytes.
  int _value = 0;

  /// Number of accumulated bits, offset by eight so that zero means one byte.
  int _bitCount = -8;

  /// Number of pending 255 bytes held back until a carry is known.
  int _pendingOnes = 0;

  /// Creates an empty partition writer.
  _Vp8BitWriter();

  /// Position of the highest set bit of a positive [value].
  static int _highestBit(int value) {
    int bit = 0;
    int rest = value >> 1;
    while (rest != 0) {
      ++bit;
      rest >>= 1;
    }
    return bit;
  }

  /// Writes [bit] using [probability] as the chance that it is zero.
  int writeBit(int bit, int probability) {
    final int split = (_range * probability) >> 8;
    if (bit != 0) {
      _value += split + 1;
      _range -= split + 1;
    } else {
      _range = split;
    }
    if (_range < 127) {
      final int shift = _normalizationShifts[_range];
      _range = _normalizedRanges[_range];
      _value <<= shift;
      _bitCount += shift;
      if (_bitCount > 0) {
        _flushByte();
      }
    }
    return bit;
  }

  /// Writes [bit] with both outcomes equally likely.
  int writeUniformBit(int bit) {
    final int split = _range >> 1;
    if (bit != 0) {
      _value += split + 1;
      _range -= split + 1;
    } else {
      _range = split;
    }
    if (_range < 127) {
      _range = _normalizedRanges[_range];
      _value <<= 1;
      ++_bitCount;
      if (_bitCount > 0) {
        _flushByte();
      }
    }
    return bit;
  }

  /// Writes the [bitCount] lowest bits of [value], most significant first.
  void writeBits(int value, int bitCount) {
    for (int mask = 1 << (bitCount - 1); mask != 0; mask >>= 1) {
      writeUniformBit(value & mask);
    }
  }

  /// Writes a flag, then [value] as a magnitude and a sign when it is not zero.
  void writeSignedBits(int value, int bitCount) {
    if (writeUniformBit(value != 0 ? 1 : 0) == 0) {
      return;
    }
    writeBits(value < 0 ? ((-value) << 1) | 1 : value << 1, bitCount + 1);
  }

  /// Writes a flag, then the eight bits of [value] when [update] is set.
  void writeOptionalByte(bool update, int value, int probability) {
    if (writeBit(update ? 1 : 0, probability) != 0) {
      writeBits(value, 8);
    }
  }

  /// Moves one settled byte out of the accumulator.
  ///
  /// A byte of 255 cannot be written yet: a later carry would have to
  /// propagate through it. Those bytes are counted in [_pendingOnes] and
  /// written once the carry is known.
  void _flushByte() {
    final int shift = 8 + _bitCount;
    final int bits = _value >> shift;
    _value -= bits << shift;
    _bitCount -= 8;
    if ((bits & 0xff) == 0xff) {
      ++_pendingOnes;
      return;
    }
    _reserve(_pendingOnes + 1);
    if ((bits & 0x100) != 0 && _position > 0) {
      ++_bytes[_position - 1];
    }
    if (_pendingOnes > 0) {
      final int filler = (bits & 0x100) != 0 ? 0x00 : 0xff;
      _bytes.fillRange(_position, _position + _pendingOnes, filler);
      _position += _pendingOnes;
      _pendingOnes = 0;
    }
    _bytes[_position++] = bits & 0xff;
  }

  /// Grows the buffer so that [extra] more bytes fit.
  void _reserve(int extra) {
    final int needed = _position + extra;
    if (needed <= _bytes.length) {
      return;
    }
    int capacity = _bytes.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final Uint8List grown = Uint8List(capacity);
    grown.setRange(0, _position, _bytes);
    _bytes = grown;
  }

  /// Pads the stream and returns every written byte.
  Uint8List finish() {
    writeBits(0, 9 - _bitCount);
    _bitCount = 0;
    _flushByte();
    return Uint8List.sublistView(_bytes, 0, _position);
  }
}
