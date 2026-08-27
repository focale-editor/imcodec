part of '../../webp.dart';

/// Reads arithmetic-coded bits from a lossy VP8 partition.
final class _Vp8BitReader {
  /// Normalization shifts indexed by the current arithmetic range.
  static const List<int> _log2Range = [
    7,
    6,
    6,
    5,
    5,
    5,
    5,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    0,
  ];

  /// Normalized arithmetic ranges indexed by their previous value.
  static const List<int> _newRange = [
    127,
    127,
    191,
    127,
    159,
    191,
    223,
    127,
    143,
    159,
    175,
    191,
    207,
    223,
    239,
    127,
    135,
    143,
    151,
    159,
    167,
    175,
    183,
    191,
    199,
    207,
    215,
    223,
    231,
    239,
    247,
    127,
    131,
    135,
    139,
    143,
    147,
    151,
    155,
    159,
    163,
    167,
    171,
    175,
    179,
    183,
    187,
    191,
    195,
    199,
    203,
    207,
    211,
    215,
    219,
    223,
    227,
    231,
    235,
    239,
    243,
    247,
    251,
    127,
    129,
    131,
    133,
    135,
    137,
    139,
    141,
    143,
    145,
    147,
    149,
    151,
    153,
    155,
    157,
    159,
    161,
    163,
    165,
    167,
    169,
    171,
    173,
    175,
    177,
    179,
    181,
    183,
    185,
    187,
    189,
    191,
    193,
    195,
    197,
    199,
    201,
    203,
    205,
    207,
    209,
    211,
    213,
    215,
    217,
    219,
    221,
    223,
    225,
    227,
    229,
    231,
    233,
    235,
    237,
    239,
    241,
    243,
    245,
    247,
    249,
    251,
    253,
    127,
  ];

  /// Encoded partition bytes.
  final _WebPBuffer input;

  /// Current arithmetic range minus one.
  late int _range;

  /// Buffered arithmetic-coded value.
  late int _value;

  /// Number of valid bits left in [_value].
  late int _bits;

  /// Whether end-of-stream padding has already been added.
  bool _eof = false;

  /// Creates a bit reader over [input].
  _Vp8BitReader({
    required this.input,
  }) {
    _range = 255 - 1;
    _value = 0;
    _bits = -8; // to load the very first 8bits
  }

  /// Reads an unsigned value containing [bits] bits.
  int readBits(int bits) {
    int value = 0;
    int remainingBits = bits;
    while (remainingBits-- > 0) {
      value |= readBit(0x80) << remainingBits;
    }
    return value;
  }

  /// Reads a sign bit and applies it to [magnitude].
  int readSignedValue(int magnitude) {
    final int split = _range >> 1;
    final int bit = _bitUpdate(split);
    _shift();
    return bit != 0 ? -magnitude : magnitude;
  }

  /// Reads a [bits]-wide magnitude followed by its sign.
  int readSignedBits(int bits) {
    final int value = readBits(bits);
    return readBoolean() == 1 ? -value : value;
  }

  /// Reads one equiprobable Boolean value.
  int readBoolean() => readBits(1);

  /// Reads one Boolean value using [probability] for the zero branch.
  int readBit(int probability) {
    final int split = (_range * probability) >> 8;
    final int bit = _bitUpdate(split);
    if (_range <= 0x7e) {
      _shift();
    }
    return bit;
  }

  /// Selects one arithmetic subrange and returns its branch.
  int _bitUpdate(int split) {
    // Make sure we have a least BITS bits in 'value_'
    if (_bits < 0) {
      _loadNewBytes();
    }

    final int pos = _bits;
    final int value = _value >> pos;
    if (value > split) {
      _range -= split + 1;
      _value -= (split + 1) << pos;
      return 1;
    } else {
      _range = split;
      return 0;
    }
  }

  /// Normalizes the arithmetic range after a bit decision.
  void _shift() {
    final int shift = _log2Range[_range];
    _range = _newRange[_range];
    _bits -= shift;
  }

  /// Loads the next full byte when the partition still has data.
  void _loadNewBytes() {
    // Read 8 bits at a time if possible.
    if (input.length >= 1) {
      // convert memory type to register type (with some zero'ing!)
      final int bits = input.readByte();
      _value = bits | (_value << 8);
      _bits += 8;
    } else {
      _loadFinalBytes(); // no need to be inlined
    }
  }

  /// Loads the final byte or one zero-padding byte at end of stream.
  void _loadFinalBytes() {
    // Only read 8bits at a time
    if (!input.isEOS) {
      _value = input.readByte() | (_value << 8);
      _bits += 8;
    } else if (!_eof) {
      // These are not strictly needed, but it makes the behaviour
      // consistent for both USE_RIGHT_JUSTIFY and !USE_RIGHT_JUSTIFY.
      _value <<= 8;
      _bits += 8;
      _eof = true;
    }
  }
}
