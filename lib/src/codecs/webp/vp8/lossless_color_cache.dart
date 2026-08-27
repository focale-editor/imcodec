part of '../../webp.dart';

/// Stores recently decoded VP8L colors in their hashed slots.
final class _Vp8LosslessColorCache {
  /// Multiplicative hash constant defined by the VP8L specification.
  static const int _hashMultiplier = 0x1e35a7bd;

  /// Packed colors indexed by their computed hash.
  final Uint32List _colors;

  /// Right shift that reduces a 32-bit hash to the configured cache size.
  final int _hashShift;

  /// Creates a color cache addressed by [hashBits] low-order bits.
  _Vp8LosslessColorCache({
    required int hashBits,
  }) : _colors = Uint32List(1 << hashBits),
       _hashShift = 32 - hashBits;

  /// Inserts [color] into its computed cache slot.
  void insert(int color) {
    final int hash = (color * _hashMultiplier) & 0xffffffff;
    _colors[hash >> _hashShift] = color;
  }

  /// Returns the packed color stored at [index].
  int lookup(int index) => _colors[index];
}
