part of '../jpeg.dart';

/// Decodes canonical JPEG Huffman codes through a flat lookup table.
///
/// The table resolves every code of [_lookupBits] bits or fewer in one step.
/// Longer codes fall back to a canonical minimum-code search, which keeps the
/// table small while still handling the sixteen-bit codes the format allows.
final class _JpegHuffmanTable {
  /// Number of leading bits resolved by the direct lookup table.
  static const int _lookupBits = 9;

  /// Packed symbol and code length for every [_lookupBits] bit prefix.
  /// The low eight bits hold the symbol and the next five its code length.
  /// A zero entry marks a prefix that needs the canonical fallback.
  final Uint16List lookup;

  /// Smallest canonical code of each length, indexed by length minus one.
  final Int32List minimumCodes;

  /// Largest canonical code of each length, or -1 when the length is unused.
  final Int32List maximumCodes;

  /// Index into [symbols] of the first value of each code length.
  final Int32List valueOffsets;

  /// Symbols in canonical code order.
  final Uint8List symbols;

  /// Creates a decoding table from canonical code lengths and symbols.
  factory _JpegHuffmanTable({required Uint8List codeLengths, required Uint8List symbols}) {
    final Int32List minimumCodes = Int32List(16);
    final Int32List maximumCodes = Int32List(16);
    final Int32List valueOffsets = Int32List(16);
    final Uint16List lookup = Uint16List(1 << _lookupBits);
    int code = 0;
    int symbolIndex = 0;
    for (int length = 1; length <= 16; length++) {
      final int count = codeLengths[length - 1];
      minimumCodes[length - 1] = code;
      valueOffsets[length - 1] = symbolIndex;
      maximumCodes[length - 1] = count == 0 ? -1 : code + count - 1;
      if (length <= _lookupBits) {
        for (int index = 0; index < count; index++) {
          final int prefix = (code + index) << (_lookupBits - length);
          final int entry = (length << 8) | symbols[symbolIndex + index];
          for (int fill = 0; fill < 1 << (_lookupBits - length); fill++) {
            lookup[prefix + fill] = entry;
          }
        }
      }
      code += count;
      symbolIndex += count;
      if (code > 1 << length) {
        throw const ImageCodecException('Oversubscribed JPEG Huffman table');
      }
      code <<= 1;
    }
    return _JpegHuffmanTable._(
      lookup: lookup,
      minimumCodes: minimumCodes,
      maximumCodes: maximumCodes,
      valueOffsets: valueOffsets,
      symbols: symbols,
    );
  }

  /// Creates a table from prepared canonical lookup data.
  const _JpegHuffmanTable._({
    required this.lookup,
    required this.minimumCodes,
    required this.maximumCodes,
    required this.valueOffsets,
    required this.symbols,
  });

  /// Number of bits resolved directly by [lookup].
  static const int lookupBits = _lookupBits;
}
