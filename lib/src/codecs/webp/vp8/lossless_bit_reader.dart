part of '../../webp.dart';

/// Reads little-endian bits from a VP8L payload.
final class _Vp8LosslessBitReader {
  /// Maximum number of bits accepted by one [readBits] call.
  static const int _maximumReadBits = 25;

  /// Bit position at which the window should be refilled.
  static const int _refillPosition = 32;

  /// Masks containing the requested number of low-order bits.
  static const List<int> _bitMasks = [
    0,
    1,
    3,
    7,
    15,
    31,
    63,
    127,
    255,
    511,
    1023,
    2047,
    4095,
    8191,
    16383,
    32767,
    65535,
    131071,
    262143,
    524287,
    1048575,
    2097151,
    4194303,
    8388607,
    16777215,
    33554431,
    67108863,
    134217727,
    268435455,
    536870911,
    1073741823,
    2147483647,
    4294967295,
  ];

  /// Encoded bytes not yet loaded into the bit window.
  final _WebPBuffer input;

  /// Two 32-bit words holding the current read window.
  final Uint32List _buffer = Uint32List(2);

  /// Byte view used to initialize [_buffer].
  late final Uint8List _bufferBytes;

  /// Number of source bits that have not been consumed yet.
  late int _remainingBitCount;

  /// Position of the next unread bit within [_buffer].
  int bitPosition = 0;

  /// Creates a lossless bit reader over [input].
  _Vp8LosslessBitReader({
    required this.input,
  }) {
    _remainingBitCount = input.length * 8;
    _bufferBytes = Uint8List.view(_buffer.buffer);
    for (int index = 0; index < _bufferBytes.length; index++) {
      _bufferBytes[index] = input.isEOS ? 0 : input.readByte();
    }
  }

  /// Returns prefetched bits without advancing [bitPosition].
  int prefetchBits() {
    if (bitPosition < 32) {
      return (_buffer[0] >> bitPosition) + ((_buffer[1] & _bitMasks[bitPosition]) * (_bitMasks[32 - bitPosition] + 1));
    }
    return bitPosition == 32 ? _buffer[1] : _buffer[1] >> (bitPosition - 32);
  }

  /// Refills the bit window when fewer than 32 bits remain in its first word.
  void fillBitWindow() {
    if (bitPosition >= _refillPosition) {
      _shiftBytes();
    }
  }

  /// Reads an unsigned value containing [bitCount] bits.
  int readBits(int bitCount) {
    if (bitCount < 0 || bitCount >= _maximumReadBits || bitCount > _remainingBitCount) {
      throw const ImageCodecException('The VP8L bitstream is truncated or requests too many bits');
    }
    final int value = prefetchBits() & _bitMasks[bitCount];
    advanceBits(bitCount);
    return value;
  }

  /// Advances past [bitCount] bits after a Huffman lookup.
  void advanceBits(int bitCount) {
    if (bitCount < 0 || bitCount > _remainingBitCount) {
      throw const ImageCodecException('The VP8L bitstream is truncated');
    }
    bitPosition += bitCount;
    _remainingBitCount -= bitCount;
    _shiftBytes();
  }

  /// Shifts complete consumed bytes out and loads replacements when available.
  void _shiftBytes() {
    while (bitPosition >= 8 && !input.isEOS) {
      final int byte = input.readByte();
      _buffer[0] = (_buffer[0] >> 8) + ((_buffer[1] & 0xff) * 0x1000000);
      _buffer[1] = (_buffer[1] >> 8) | (byte * 0x1000000);
      bitPosition -= 8;
    }
  }
}
