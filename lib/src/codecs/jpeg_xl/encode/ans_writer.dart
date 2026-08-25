import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_tables.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_writer.dart';

/// ANS (rANS) encoding — the exact inverse of `AnsSymbolDistribution` and
/// its 12-bit / 16-bit-renorm state machine. Prefix codes pay a
/// 1-bit-per-symbol floor; ANS spends fractional bits, which wins on the
/// skewed histograms typical of image residuals.

const _precisionBits = 12;

/// Stores the precision state used internally by the JPEG XL codec.
///
const int _precision = 1 << _precisionBits; // 4096
/// Stores the ans renorm lower state used internally by the JPEG XL codec.
///
const int _ansRenormLower = 1 << 16;

/// Stores the ans final state state used internally by the JPEG XL codec.
///
const _ansFinalState = 0x130000;

/// (code, length) to write for each log-count symbol 0..13, derived from the
/// fixed distribution-prefix table the decoder reads with.
final List<(int, int)> _distPrefixEncode = () {
  // The decoder peeks 7 bits, indexes the expanded table, and skips the
  // entry's length. So a symbol's LSB-first code is the low `length` bits
  // shared by every table index that maps to it.
  final out = List<(int, int)>.filled(14, (0, 0));
  final seen = List<bool>.filled(14, false);
  for (var i = 0; i < ansDistPrefixSymbols.length; i++) {
    final int s = ansDistPrefixSymbols[i];
    if (seen[s]) {
      continue;
    }
    seen[s] = true;
    final int len = ansDistPrefixLengths[i];
    out[s] = (i & ((1 << len) - 1), len);
  }
  return out;
}();

/// Normalizes raw [counts] over [alphabetSize] symbols to frequencies that
/// sum to exactly [_precision], preserving zeros and giving every used
/// symbol at least 1.
Int32List normalizeFrequencies(List<int> counts, int alphabetSize) {
  final freqs = Int32List(alphabetSize);
  var total = 0;
  for (var i = 0; i < alphabetSize; i++) {
    total += counts[i];
  }
  if (total == 0) {
    freqs[0] = _precision;
    return freqs;
  }
  var used = 0;
  var sum = 0;
  var maxFreq = 0;
  var maxIdx = 0;
  for (var i = 0; i < alphabetSize; i++) {
    if (counts[i] == 0) {
      continue;
    }
    used++;
    int f = (counts[i] * _precision) ~/ total;
    if (f == 0) {
      f = 1;
    }
    if (f > _precision - 1) {
      f = _precision - 1;
    }
    freqs[i] = f;
    sum += f;
    if (f > maxFreq) {
      maxFreq = f;
      maxIdx = i;
    }
  }
  if (used == 1) {
    freqs[maxIdx] = _precision;
    return freqs;
  }
  // Fix the rounding drift on the most frequent symbol.
  int diff = _precision - sum;
  if (freqs[maxIdx] + diff < 1) {
    // Spread a large negative correction across symbols with room.
    for (var i = 0; i < alphabetSize && diff < 0; i++) {
      while (freqs[i] > 1 && diff < 0) {
        freqs[i]--;
        diff++;
      }
    }
  } else {
    freqs[maxIdx] += diff;
  }
  return freqs;
}

/// Writes an ANS symbol distribution ([freqs] must sum to [_precision]).
/// Uses the general log-count format with shift 13 (exact), or the simple
/// single-peak format when only one symbol is present.
void writeAnsDistribution(BitWriter w, Int32List freqs) {
  final int alphabetSize = freqs.length;
  var used = 0;
  var single = -1;
  for (var i = 0; i < alphabetSize; i++) {
    if (freqs[i] != 0) {
      used++;
      single = i;
    }
  }
  if (used == 1 && freqs[single] == _precision) {
    // Simple distribution, single peak.
    w.writeBool(true); // is_simple
    w.writeBool(false); // not dual
    _writeU8(w, single);
    return;
  }

  // General distribution.
  w.writeBool(false); // not simple
  w.writeBool(false); // not flat
  // shift = 13 -> shift + 1 = 14 = (readBits(3) | 8): len = 3, bits = 6.
  w
    ..writeBool(true)
    ..writeBool(true)
    ..writeBool(true); // len = 3
  w.writeBits(6, 3); // shift value
  // alphabet_size = 3 + readU8(); pad up to at least 3.
  final declaredSize = alphabetSize < 3 ? 3 : alphabetSize;
  _writeU8(w, declaredSize - 3);

  // omitPos = first symbol with the maximum log-count; its frequency is
  // recovered as precision - sum(others) and carries no refinement bits.
  final logCounts = Int32List(declaredSize);
  var omitLog = -1;
  var omitPos = -1;
  for (var i = 0; i < declaredSize; i++) {
    final int f = i < alphabetSize ? freqs[i] : 0;
    logCounts[i] = f == 0 ? 0 : _bitLength(f);
    if (logCounts[i] > omitLog) {
      omitLog = logCounts[i];
      omitPos = i;
    }
  }
  // Pass 1: all log-count VLCs (the decoder reads these before any
  // refinement bits). Pass 2: refinement bits, same order.
  for (var i = 0; i < declaredSize; i++) {
    final (int code, int bits) = _distPrefixEncode[logCounts[i]];
    w.writeBits(code, bits);
  }
  for (var i = 0; i < declaredSize; i++) {
    if (i == omitPos || logCounts[i] == 0 || logCounts[i] == 1) {
      continue;
    }
    // shift 13 makes bitcount == logCount - 1, so refinement = f - 2^(L-1).
    final int l = logCounts[i];
    w.writeBits(freqs[i] - (1 << (l - 1)), l - 1);
  }
}

/// Alias table (mirror of `_generateAliasMapping`) plus its inverse: for a
/// symbol and an offset in `[0, freq)`, the 12-bit slot that decodes to it.
final class AnsAliasTable {
  /// Stores the freqs value used while processing JPEG XL data.
  ///
  final Int32List freqs;

  /// Stores the log bucket size state used internally by the JPEG XL codec.
  ///
  late final int _logBucketSize;

  /// Stores the enc table state used internally by the JPEG XL codec.
  ///
  late final List<Int32List> _encTable;

  /// Creates Ans alias table data for JPEG XL processing.
  ///
  AnsAliasTable({
    required this.freqs,
    required int logAlphabetSize,
  }) {
    final int tableSize = 1 << logAlphabetSize;
    final int bucketSize = 1 << (_precisionBits - logAlphabetSize);
    _logBucketSize = _precisionBits - logAlphabetSize;
    final symbols = Int32List(tableSize);
    final cutoffs = Int32List(tableSize);
    final offsets = Int32List(tableSize);

    var uniqPos = -1;
    var usedCount = 0;
    var lastUsed = 0;
    for (var i = 0; i < freqs.length; i++) {
      if (freqs[i] != 0) {
        usedCount++;
        lastUsed = i;
      }
    }
    if (usedCount == 1 && freqs[lastUsed] == _precision) {
      uniqPos = lastUsed;
    }

    if (uniqPos >= 0) {
      for (var i = 0; i < tableSize; i++) {
        symbols[i] = uniqPos;
        offsets[i] = i * bucketSize;
        cutoffs[i] = 0;
      }
    } else {
      final overfull = <int>[];
      final underfull = <int>[];
      for (var i = 0; i < freqs.length; i++) {
        cutoffs[i] = freqs[i];
        symbols[i] = i;
        if (cutoffs[i] > bucketSize) {
          overfull.add(i);
        } else if (cutoffs[i] < bucketSize) {
          underfull.add(i);
        }
      }
      for (int i = freqs.length; i < tableSize; i++) {
        underfull.add(i);
      }
      while (overfull.isNotEmpty) {
        final int u = underfull.removeLast();
        final int o = overfull.removeLast();
        final int by = bucketSize - cutoffs[u];
        cutoffs[o] -= by;
        symbols[u] = o;
        offsets[u] = cutoffs[o];
        if (cutoffs[o] < bucketSize) {
          underfull.add(o);
        } else if (cutoffs[o] > bucketSize) {
          overfull.add(o);
        }
      }
      for (var i = 0; i < tableSize; i++) {
        if (cutoffs[i] == bucketSize) {
          symbols[i] = i;
          offsets[i] = 0;
          cutoffs[i] = 0;
        } else {
          offsets[i] -= cutoffs[i];
        }
      }
    }

    // Invert: encTable[symbol] maps offset -> 12-bit slot. The decoder's
    // slot is the low 12 bits of the state (0..4095); the alias arrays are
    // indexed by slot >> logBucketSize (the bucket), so iterate all slots.
    _encTable = [for (final f in freqs) Int32List(f)];
    final int bucketMask = bucketSize - 1;
    for (var slot = 0; slot < _precision; slot++) {
      final int i = slot >> _logBucketSize;
      final int pos = slot & bucketMask;
      final bool greater = pos >= cutoffs[i];
      final int symbol = greater ? symbols[i] : i;
      final int offset = greater ? offsets[i] + pos : pos;
      if (symbol < _encTable.length && offset < _encTable[symbol].length) {
        _encTable[symbol][offset] = slot;
      }
    }
  }

  /// The 12-bit slot for symbol [s] at [offset] in `[0, freqs[s])`.
  int slot(int s, int offset) => _encTable[s][offset];
}

/// Encodes a section's symbols with a shared rANS state (LIFO) plus the
/// raw hybrid-uint extra bits the decoder reads after each symbol. Symbols
/// are consumed in reverse; a forward decode reproduces them in order.
final class AnsEncoder {
  /// Stores the tables state used internally by the JPEG XL codec.
  ///
  final List<int> _tables = []; // alias table index per value
  /// Processes the tokens data used by the JPEG XL codec.
  ///
  final List<int> _tokens = []; // rANS symbol (hybrid token) per value
  /// Stores the extra state used internally by the JPEG XL codec.
  ///
  final List<int> _extra = []; // raw hybrid extra value
  /// Processes the extra bits data used by the JPEG XL codec.
  ///
  final List<int> _extraBits = []; // number of raw bits (0 for none)

  /// Stores the alias tables value used while processing JPEG XL data.
  ///
  final List<AnsAliasTable> aliasTables;

  /// Creates Ans encoder data for JPEG XL processing.
  ///
  AnsEncoder({
    required this.aliasTables,
  });

  /// Processes add information in a JPEG XL codestream.
  ///
  void add(int tableIndex, int token, {int extra = 0, int extraBits = 0}) {
    _tables.add(tableIndex);
    _tokens.add(token);
    _extra.add(extra);
    _extraBits.add(extraBits);
  }

  /// Appends the encoded stream to [w]: a 32-bit initial state, then the
  /// renorm words and raw extra bits interleaved exactly as the decoder
  /// reads them.
  void finish(BitWriter w) {
    // Chunks are collected during the reverse pass, then reversed to get the
    // forward stream. For value k the forward order is [refill?][extra];
    // reversed, that means appending extra first, then the renorm word.
    final chunkBits = <int>[];
    final chunkLen = <int>[];
    const int xMax = (_ansRenormLower >> _precisionBits) << 16;
    int state = _ansFinalState;
    for (int k = _tokens.length - 1; k >= 0; k--) {
      if (_extraBits[k] > 0) {
        chunkBits.add(_extra[k]);
        chunkLen.add(_extraBits[k]);
      }
      final AnsAliasTable table = aliasTables[_tables[k]];
      final int s = _tokens[k];
      final int f = table.freqs[s];
      while (state >= xMax * f) {
        chunkBits.add(state & 0xFFFF);
        chunkLen.add(16);
        state >>= 16;
      }
      state = ((state ~/ f) << _precisionBits) | table.slot(s, state % f);
    }
    w.writeBits(state & 0xFFFF, 16);
    w.writeBits((state >> 16) & 0xFFFF, 16);
    for (int i = chunkBits.length - 1; i >= 0; i--) {
      w.writeBits(chunkBits[i], chunkLen[i]);
    }
  }
}

/// Writes u8.
///
void _writeU8(BitWriter w, int value) {
  // Mirror of BitReader.readU8's var-u8 encoding.
  if (value == 0) {
    w.writeBool(false);
    return;
  }
  w.writeBool(true);
  final int nbits = _bitLength(value) - 1;
  w.writeBits(nbits, 3);
  w.writeBits(value - (1 << nbits), nbits);
}

/// Processes the bit length data used by the JPEG XL codec.
///
int _bitLength(int v) => v <= 0 ? 0 : v.bitLength;
