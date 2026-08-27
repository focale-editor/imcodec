import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/int_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/encoder/ans_encoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/hybrid_uint.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_writer.dart';

/// Entropy encoding (prefix-code variant): the exact mirror of
/// `EntropyStream.read` with `use_prefix_code = 1` and no LZ77.

int _reverseBits32(int value) {
  int v = value;
  v = ((v >> 1) & 0x55555555) | ((v & 0x55555555) << 1);
  v = ((v >> 2) & 0x33333333) | ((v & 0x33333333) << 2);
  v = ((v >> 4) & 0x0F0F0F0F) | ((v & 0x0F0F0F0F) << 4);
  v = ((v >> 8) & 0x00FF00FF) | ((v & 0x00FF00FF) << 8);
  return ((v >> 16) & 0xFFFF) | ((v & 0xFFFF) << 16);
}

/// Canonical LSB-first codes for the given lengths (0 = unused), matching
/// `VlcTable.canonical`: codes assigned in (length asc, symbol asc) order.
List<int> canonicalCodes(List<int> lengths) {
  final order = <int>[
    for (var s = 0; s < lengths.length; s++)
      if (lengths[s] > 0) s,
  ]..sort((a, b) => lengths[a] != lengths[b] ? lengths[a] - lengths[b] : a - b);
  final codes = List<int>.filled(lengths.length, 0);
  var code = 0;
  for (final s in order) {
    codes[s] = _reverseBits32(code) & ((1 << lengths[s]) - 1);
    code += 1 << (32 - lengths[s]);
  }
  // 0x100000000 (not `1 << 32`): a *computed* shift by exactly 32 silently
  // gives 0 on dart2js even though the value is exactly representable.
  assert(order.length <= 1 || code == 0x100000000, 'canonical code lengths must satisfy Kraft exactly');
  return codes;
}

/// Length-limited Huffman code lengths with an exact Kraft sum (required
/// by the decoder), for at least two used symbols.
List<int> huffmanLengths(List<int> counts, int limit) {
  final int n = counts.length;
  final used = <int>[
    for (var s = 0; s < n; s++)
      if (counts[s] > 0) s,
  ];
  assert(used.length >= 2, 'A Huffman tree requires at least two symbols.');
  final lengths = List<int>.filled(n, 0);

  // Standard Huffman via repeated merging (small alphabets; simplicity
  // over speed).
  final nodeCount = <int>[for (final s in used) counts[s]];
  final nodeSyms = <List<int>>[
    for (final s in used) [s],
  ];
  while (nodeCount.length > 1) {
    var a = 0;
    for (var i = 1; i < nodeCount.length; i++) {
      if (nodeCount[i] < nodeCount[a]) {
        a = i;
      }
    }
    var b = a == 0 ? 1 : 0;
    for (var i = 0; i < nodeCount.length; i++) {
      if (i != a && nodeCount[i] < nodeCount[b]) {
        b = i;
      }
    }
    for (final int s in nodeSyms[a]) {
      lengths[s]++;
    }
    for (final int s in nodeSyms[b]) {
      lengths[s]++;
    }
    nodeCount[a] += nodeCount[b];
    nodeSyms[a] = [...nodeSyms[a], ...nodeSyms[b]];
    nodeCount.removeAt(b);
    nodeSyms.removeAt(b);
  }

  // Clamp to the limit, then repair the Kraft sum to be exact.
  final int target = 1 << limit;
  int kraft() {
    var k = 0;
    for (final s in used) {
      k += 1 << (limit - lengths[s]);
    }
    return k;
  }

  for (final s in used) {
    if (lengths[s] > limit) {
      lengths[s] = limit;
    }
  }
  int k = kraft();
  while (k > target) {
    // Lengthen the cheapest lengthenable symbol.
    var pick = -1;
    for (final s in used) {
      if (lengths[s] < limit && (pick < 0 || counts[s] < counts[pick])) {
        pick = s;
      }
    }
    k -= 1 << (limit - lengths[pick] - 1);
    lengths[pick]++;
  }
  var improved = true;
  while (k < target && improved) {
    improved = false;
    // Shorten the most frequent symbol that still fits.
    var pick = -1;
    for (final s in used) {
      if (lengths[s] > 1 && k + (1 << (limit - lengths[s])) <= target && (pick < 0 || counts[s] > counts[pick])) {
        pick = s;
      }
    }
    if (pick >= 0) {
      k += 1 << (limit - lengths[pick]);
      lengths[pick]--;
      improved = true;
    }
  }
  assert(k == target, 'kraft repair failed: $k != $target');
  return lengths;
}

// Fixed level-0 code for level-1 code lengths (mirror of prefix.dart's
// _level0Table): symbol -> (LSB-first code, bits).
/// Fixed prefix codes used to encode the code-length alphabet.
const _codeLengthPrefixCodes = <int, (int, int)>{0: (0, 2), 4: (1, 2), 3: (2, 2), 2: (3, 3), 1: (7, 4), 5: (15, 4)};

/// Serialization order of the code-length alphabet.
const _codeLengthOrder = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15];

/// Writes a Brotli-style prefix code for [lengths] (level-2 code lengths of
/// an alphabet), including the level-1 code-length code.
void _writeComplexPrefixCode(BitWriter w, List<int> lengths) {
  // Tokenize the length sequence with 16 (repeat prev) / 17 (zeros) RLE,
  // stopping after the last used symbol (the reader stops at full Kraft).
  int last = lengths.length - 1;
  while (lengths[last] == 0) {
    last--;
  }
  final tokens = <(int, int, int)>[]; // (symbol, extraValue, extraBits)
  var prev = 8;
  var i = 0;
  while (i <= last) {
    final int len = lengths[i];
    var run = 1;
    while (i + run <= last && lengths[i + run] == len) {
      run++;
    }
    if (len == 0) {
      if (run < 3) {
        for (var j = 0; j < run; j++) {
          tokens.add((0, 0, 0));
        }
      } else {
        // Bijective base-8 digits of (run - 2), MSB first.
        int m = run - 2;
        final digits = <int>[];
        while (m > 0) {
          final int d = (m - 1) % 8 + 1;
          digits.add(d);
          m = (m - d) ~/ 8;
        }
        for (final int d in digits.reversed) {
          tokens.add((17, d - 1, 3));
        }
      }
    } else {
      var reps = run;
      if (len != prev) {
        tokens.add((len, 0, 0));
        prev = len;
        reps--;
      }
      if (reps < 3) {
        for (var j = 0; j < reps; j++) {
          tokens.add((len, 0, 0));
        }
      } else {
        int m = reps - 2;
        final digits = <int>[];
        while (m > 0) {
          final int d = (m - 1) % 4 + 1;
          digits.add(d);
          m = (m - d) ~/ 4;
        }
        for (final int d in digits.reversed) {
          tokens.add((16, d - 1, 2));
        }
      }
    }
    i += run;
  }

  // Level-1 code over the token kinds.
  final level1Counts = List<int>.filled(18, 0);
  for (final t in tokens) {
    level1Counts[t.$1]++;
  }
  final kinds = <int>[
    for (var s = 0; s < 18; s++)
      if (level1Counts[s] > 0) s,
  ];
  List<int> level1Lengths;
  List<int> level1Codes;
  if (kinds.length == 1) {
    // Single kind: the reader builds a zero-bit table.
    level1Lengths = List<int>.filled(18, 0);
    level1Lengths[kinds.single] = 1;
    level1Codes = List<int>.filled(18, 0);
  } else {
    level1Lengths = huffmanLengths(level1Counts, 5);
    level1Codes = canonicalCodes(level1Lengths);
  }

  w.writeBits(0, 2); // hskip = 0
  // The reader stops once the level-1 Kraft sum completes (unless only one
  // code exists); emit exactly the entries it will read.
  var totalCode = 0;
  for (var j = 0; j < 18; j++) {
    final int len = level1Lengths[_codeLengthOrder[j]];
    final (int code, int bits) = _codeLengthPrefixCodes[len]!;
    w.writeBits(code, bits);
    if (len != 0 && kinds.length > 1) {
      totalCode += 32 >> len;
      if (totalCode >= 32) {
        break;
      }
    }
  }
  final bool emitPerToken = kinds.length > 1;
  for (final (sym, extra, extraBits) in tokens) {
    if (emitPerToken) {
      w.writeBits(level1Codes[sym], level1Lengths[sym]);
    }
    if (extraBits > 0) {
      w.writeBits(extra, extraBits);
    }
  }
}

/// Writes the prefix code for a cluster histogram; returns per-symbol
/// (code, length) for the payload phase.
(List<int>, List<int>) writePrefixCode(BitWriter w, List<int> counts, int alphabetSize) {
  final int logAlphabetSize = ceilLog1p(alphabetSize - 1);
  final used = <int>[
    for (var s = 0; s < alphabetSize; s++)
      if (counts[s] > 0) s,
  ];
  if (used.length <= 1) {
    // Simple code, nsym = 1 (alphabetSize > 1 here; size 1 handled by
    // the caller, which writes no code at all).
    w.writeBits(1, 2); // hskip == 1 -> simple
    w.writeBits(0, 2); // nsym - 1 = 0
    final int sym = used.isEmpty ? 0 : used.single;
    w.writeBits(sym, logAlphabetSize);
    final codes = List<int>.filled(alphabetSize, 0);
    final codeLengths = List<int>.filled(alphabetSize, 0);
    return (codes, codeLengths); // zero-bit symbol
  }
  if (used.length <= 4) {
    w.writeBits(1, 2); // simple
    w.writeBits(used.length - 1, 2);
    final codeLengths = List<int>.filled(alphabetSize, 0);
    switch (used.length) {
      case 2:
        for (final s in used) {
          w.writeBits(s, logAlphabetSize);
          codeLengths[s] = 1;
        }
      case 3:
        // First listed symbol gets the 1-bit code: pick the most frequent.
        used.sort((a, b) => counts[b] - counts[a]);
        w.writeBits(used[0], logAlphabetSize);
        final List<int> rest = [used[1], used[2]]..sort();
        w.writeBits(rest[0], logAlphabetSize);
        w.writeBits(rest[1], logAlphabetSize);
        codeLengths[used[0]] = 1;
        codeLengths[rest[0]] = 2;
        codeLengths[rest[1]] = 2;
      default:
        // Flat 2-bit code (tree-select variant not emitted).
        for (final s in used) {
          w.writeBits(s, logAlphabetSize);
          codeLengths[s] = 2;
        }
        w.writeBool(false); // tree_select
    }
    return (canonicalCodes(codeLengths), codeLengths);
  }
  final List<int> codeLengths = huffmanLengths(counts, 15);
  _writeComplexPrefixCode(w, codeLengths);
  return (canonicalCodes(codeLengths), codeLengths);
}

/// Splits [value] per [config]; returns (token, extraBits, extraValue).
(int, int, int) tokenizeHybrid(HybridIntegerConfig config, int value) {
  final int split = 1 << config.splitExponent;
  if (value < split) {
    return (value, 0, 0);
  }
  final int lsb = config.lsbInToken;
  final int msb = config.msbInToken;
  final int low = value & ((1 << lsb) - 1);
  final int high = value >> lsb;
  final int n = high.bitLength - 1 - msb;
  final int msbBits = (high >> n) & ((1 << msb) - 1);
  // n mirrors _readHybridInteger's decoder-side n, which can reach 32 for
  // large values: `(1 << n) - 1` would break on dart2js there (see
  // wideShl's doc), so build the mask via wideShl instead of a bare `<<`.
  final int extra = high & (wideShl(1, n) - 1);
  final int token = split + (((n - (config.splitExponent - msb - lsb)) << (msb + lsb)) | (msbBits << lsb) | low);
  return (token, n, extra);
}

/// One LZ77-processed op stream: literals interleaved with
/// (length, distance) matches, ready for histogramming and emission.
final class Lz77Operations {
  /// Operation kind at each encoded position: zero for literals, one for matches.
  final IntBuffer operationKinds = IntBuffer(1 << 12);

  /// Entropy context associated with each operation.
  final IntBuffer contexts = IntBuffer(1 << 12);

  /// Literal value or match length associated with each operation.
  final IntBuffer literalValuesOrMatchLengths = IntBuffer(1 << 12);

  /// Backward distance for each match, or zero for literals.
  final IntBuffer matchDistances = IntBuffer(1 << 12);
}

/// Token slots reserved per context before the count block has to grow.
/// Literal tokens stay below [lz77MinSymbol] and match symbols add a small
/// length code on top, so this covers every alphabet the encoder produces.
const int _defaultAlphabetCapacity = 288;

/// First entropy symbol reserved for an LZ77 match.
const int lz77MinSymbol = 224;

/// Minimum number of values represented by an LZ77 match.
const int lz77MinLength = 3;

/// Hybrid-integer representation used for LZ77 match lengths.
const HybridIntegerConfig lz77LengthConfiguration = HybridIntegerConfig(splitExponent: 4, msbInToken: 0, lsbInToken: 0);

/// LZ77 matcher effort. [shallow] is the long-standing greedy hash-chain
/// (depth 24, no lookahead) kept as a never-worse baseline candidate. [deep]
/// searches far deeper with usesLazyMatching matching (one-step lookahead) and a
/// nice-length early exit — a big win on highly repetitive content (regular
/// screentone/halftone, a core manga type and where LZ77 wins) but, because a
/// greedy parse's entropy-coded cost is non-monotonic in these knobs, *not*
/// universally smaller than [shallow] (it can lose on e.g. a synthetic gradient
/// whose residuals are long zero runs). The encoder assembles both and keeps
/// the smaller, so the pair is never-worse; [deep] is only tried when LZ77 is
/// already beating the plain code (see the caller), so diverse content that
/// codes plainly never pays for it.
enum Lz77Effort {
  // shallow reproduces the long-standing matcher exactly (depth 24, break once
  // a match reaches 4096, no lookahead) so that keeping it as a candidate makes
  // the output provably never-worse than before the deep matcher existed:
  // final size = min(plain, shallow-lz, deep-lz) <= min(plain, shallow-lz).
  /// Uses a shallow greedy search without lookahead.
  shallow(searchDepth: 24, preferredMatchLength: 4096, usesLazyMatching: false),

  /// Uses a deeper search with one-symbol lazy matching.
  deep(searchDepth: 256, preferredMatchLength: 512, usesLazyMatching: true);

  /// Maximum number of hash-chain candidates tested for each match.
  final int searchDepth;

  /// Match length at which the search may stop early.
  final int preferredMatchLength;

  /// Whether a longer match at the next position may replace the current one.
  final bool usesLazyMatching;

  /// Creates an LZ77 search-effort configuration.
  const Lz77Effort({required this.searchDepth, required this.preferredMatchLength, required this.usesLazyMatching});
}

/// Hash-chain LZ77 over the token-value sequence of one section at [effort].
/// Distances are in value positions (the decoder's window semantics).
/// Any valid factorization decodes to the same values, so correctness is
/// effort-independent (the encoder round-trip / corpus gates verify it); only
/// the coded size differs, and the caller keeps the smaller of the candidates.
Lz77Operations lz77Compress(List<int> contexts, List<int> values, {Lz77Effort effort = Lz77Effort.shallow}) {
  final ops = Lz77Operations();
  final int n = values.length;
  const hashBits = 15;
  final int searchDepth = effort.searchDepth;
  final int preferredMatchLength = effort.preferredMatchLength;
  final bool usesLazyMatching = effort.usesLazyMatching;
  // Typed scratch: these are sized from the section length, so a `List<int>`
  // here cost twice the memory and a garbage-collector-visible fill per call.
  final Int32List chains = Int32List(1 << hashBits)..fillRange(0, 1 << hashBits, -1);
  final Int32List prev = Int32List(n < 1 ? 1 : n)..fillRange(0, n < 1 ? 1 : n, -1);

  int hash(int i) {
    int h = values[i] * 0x9E3779B1;
    h ^= values[i + 1] * 0x85EBCA6B;
    h ^= values[i + 2] * 0xC2B2AE35;
    return (h ^ (h >>> 13)) & ((1 << hashBits) - 1);
  }

  void insert(int i) {
    if (i + 2 >= n) {
      return;
    }
    final int h = hash(i);
    prev[i] = chains[h];
    chains[h] = i;
  }

  // Best (length, distance) for a match starting at [i], packed as
  // `(len << 24) | dist` to avoid a record/list allocation in this hot loop
  // (dist < 2^20 always fits the low 24 bits); 0 means no usable match.
  int findMatch(int i) {
    if (i + lz77MinLength > n || i + 2 >= n) {
      return 0;
    }
    final int maxLen = n - i;
    var bestLen = 0;
    var bestDist = 0;
    int cand = chains[hash(i)];
    var depth = 0;
    while (cand >= 0 && depth < searchDepth) {
      final int dist = i - cand;
      if (dist > (1 << 20) - 1) {
        break;
      }
      // Only attempt the full compare when this candidate can beat bestLen —
      // its value at offset bestLen must already match. This standard
      // hash-chain shortcut is what makes a deep search affordable.
      if (bestLen == 0 || values[cand + bestLen] == values[i + bestLen]) {
        var len = 0;
        while (len < maxLen && values[cand + len] == values[i + len]) {
          len++;
        }
        if (len > bestLen) {
          bestLen = len;
          bestDist = dist;
          // Stop at a maximal match (nothing can beat matching to the buffer
          // end) or a good-enough one. Reaching maxLen also keeps the
          // `bestLen`-offset shortcut above in range: on any iteration that
          // continues, bestLen < maxLen, so `i + bestLen < n`.
          if (len == maxLen || len >= preferredMatchLength) {
            break;
          }
        }
      }
      cand = prev[cand];
      depth++;
    }
    return bestLen == 0 ? 0 : (bestLen << 24) | bestDist;
  }

  void emitLiteral(int i) {
    ops.operationKinds.add(0);
    ops.contexts.add(contexts[i]);
    ops.literalValuesOrMatchLengths.add(values[i]);
    ops.matchDistances.add(0);
  }

  var i = 0;
  int pending = findMatch(0); // best match starting at the current position
  while (i < n) {
    final int mLen = pending >> 24;
    if (mLen >= lz77MinLength) {
      insert(i);
      // Lazy: if i+1 starts a strictly longer match, emit a literal here and
      // take that one instead.
      final int next = usesLazyMatching && i + 1 < n ? findMatch(i + 1) : 0;
      if ((next >> 24) > mLen) {
        emitLiteral(i);
        i++;
        pending = next;
        continue;
      }
      ops.operationKinds.add(1);
      ops.contexts.add(contexts[i]);
      ops.literalValuesOrMatchLengths.add(mLen);
      ops.matchDistances.add(pending & 0xFFFFFF);
      final int end = i + mLen;
      for (int j = i + 1; j < end; j++) {
        insert(j);
      }
      i = end;
    } else {
      emitLiteral(i);
      insert(i);
      i++;
    }
    pending = i < n ? findMatch(i) : 0;
  }
  return ops;
}

/// Built entropy codes: serializes the stream header once, then emits
/// tokens into any number of section writers (prefix codes are stateless).
final class EntropyCodes {
  /// Hybrid-integer representation used to tokenize source values.
  final HybridIntegerConfig config;

  /// Pixel contexts (excluding the LZ77 distance cluster, when present).
  final int contextCount;

  /// Canonical prefix code assigned to every context and token.
  final List<List<int>> _codes;

  /// Prefix-code length assigned to every context and token.
  final List<List<int>> _codeLengths;

  /// Effective token alphabet size for each entropy context.
  final List<int> _alphabetSizes;

  /// Token-frequency histogram for each entropy context.
  final List<List<int>> _histograms;

  /// Token counts for every context, laid out as one flat row-major block.
  /// A nested hash map cost two lookups per coded symbol, and a separate row
  /// per context cost one allocation per context; a single block pays neither.
  Int32List _counts = Int32List(0);

  /// Number of token slots reserved for each context in [_counts].
  int _countsStride = 0;

  /// Highest token seen in each context, or -1 when the context is unused.
  Int32List _maximumTokens = Int32List(0);

  /// Whether entropy coding uses LZ77 references.
  bool usesLz77 = false;

  /// Estimated cost of hybrid-integer payload bits.
  double _extraBits = 0;

  /// Alias tables used when the selected representation is ANS.
  List<AnsAliasTable>? _ansTables;

  /// Base-two logarithm of the ANS alphabet table size.
  int _ansLogarithm = 8;

  /// Creates a fully allocated entropy-code set.
  EntropyCodes._({
    required this.config,
    required this._codes,
    required this._codeLengths,
    required this._alphabetSizes,
    required this._histograms,
    required this.contextCount,
  });

  /// Builds histograms and prefix codes over all [contexts]/[values].
  factory EntropyCodes.build({
    required int contextCount,
    required List<int> contexts,
    required List<int> values,
    required HybridIntegerConfig config,
  }) => EntropyCodes.buildSections(
    contextCount: contextCount,
    contextSections: <List<int>>[contexts],
    valueSections: <List<int>>[values],
    config: config,
  );

  /// Builds codes directly over aligned sections without flattening them.
  factory EntropyCodes.buildSections({
    required int contextCount,
    required List<List<int>> contextSections,
    required List<List<int>> valueSections,
    required HybridIntegerConfig config,
  }) {
    if (contextSections.length != valueSections.length) {
      throw ArgumentError('Entropy context and value section counts differ.');
    }
    final codes = EntropyCodes._(config: config, codes: [], codeLengths: [], alphabetSizes: [], histograms: [], contextCount: contextCount);
    for (int section = 0; section < valueSections.length; section++) {
      final List<int> contexts = contextSections[section];
      final List<int> values = valueSections[section];
      if (contexts.length != values.length) {
        throw ArgumentError('Entropy context and value lengths differ in section $section.');
      }
      for (int index = 0; index < values.length; index++) {
        final (int token, int extraBitCount, _) = tokenizeHybrid(config, values[index]);
        codes._count(contexts[index], token, extraBitCount);
      }
    }
    codes._finishHistograms(contextCount);
    return codes;
  }

  /// Builds codes from token histograms collected while producing values.
  factory EntropyCodes.fromTokenCounts({
    required List<Int32List> tokenCounts,
    required Int32List extraBitCounts,
    required HybridIntegerConfig config,
  }) {
    if (tokenCounts.length != extraBitCounts.length) {
      throw ArgumentError('Entropy token and payload-bit context counts differ.');
    }
    final int contextCount = tokenCounts.length;
    final EntropyCodes codes = EntropyCodes._(
      config: config,
      codes: <List<int>>[],
      codeLengths: <List<int>>[],
      alphabetSizes: <int>[],
      histograms: <List<int>>[],
      contextCount: contextCount,
    );
    for (int context = 0; context < contextCount; context++) {
      final Int32List counts = tokenCounts[context];
      int maximumToken = -1;
      for (int token = counts.length - 1; token >= 0; token--) {
        if (counts[token] != 0) {
          maximumToken = token;
          break;
        }
      }
      final int alphabetSize = maximumToken < 0 ? 1 : maximumToken + 1;
      codes
        .._alphabetSizes.add(alphabetSize)
        .._histograms.add(<int>[for (int token = 0; token < alphabetSize; token++) counts[token]])
        .._codes.add(const <int>[])
        .._codeLengths.add(const <int>[]);
      codes._extraBits += extraBitCounts[context];
    }
    return codes;
  }

  /// Builds codes over LZ77 op streams: [contextCount] pixel contexts plus
  /// one distance cluster (the last).
  factory EntropyCodes.buildLz77({
    required int contextCount,
    required List<Lz77Operations> sections,
    required HybridIntegerConfig config,
  }) {
    final codes = EntropyCodes._(config: config, codes: [], codeLengths: [], alphabetSizes: [], histograms: [], contextCount: contextCount)..usesLz77 = true;
    for (final ops in sections) {
      for (var i = 0; i < ops.operationKinds.length; i++) {
        if (ops.operationKinds[i] == 0) {
          final (int token, int nbits, _) = tokenizeHybrid(config, ops.literalValuesOrMatchLengths[i]);
          assert(token < lz77MinSymbol, 'literal token collides with LZ77 length symbols');
          codes._count(ops.contexts[i], token, nbits);
        } else {
          final (int lt, int lnbits, _) = tokenizeHybrid(lz77LengthConfiguration, ops.literalValuesOrMatchLengths[i] - lz77MinLength);
          codes._count(ops.contexts[i], lz77MinSymbol + lt, lnbits);
          final (int dt, int dnbits, _) = tokenizeHybrid(config, ops.matchDistances[i] + 119);
          codes._count(contextCount, dt, dnbits);
        }
      }
    }
    codes._finishHistograms(contextCount + 1);
    return codes;
  }

  /// Number of clusters.
  int get _clusterCount => usesLz77 ? contextCount + 1 : contextCount;

  /// Counts one coded [token] in [context].
  void _count(int context, int token, [int extraBits = 0]) {
    if (context >= _maximumTokens.length || token >= _countsStride) {
      _reserveCounts(context, token);
    }
    _counts[context * _countsStride + token]++;
    if (token > _maximumTokens[context]) {
      _maximumTokens[context] = token;
    }
    _extraBits += extraBits;
  }

  /// Grows the count block so that [context] and [token] both fit.
  void _reserveCounts(int context, int token) {
    final int contexts = _maximumTokens.length > context ? _maximumTokens.length : context + 1;
    int stride = _countsStride < 1 ? _defaultAlphabetCapacity : _countsStride;
    while (stride <= token) {
      stride *= 2;
    }
    final Int32List counts = Int32List(contexts * stride);
    if (_countsStride > 0) {
      for (var currentContext = 0; currentContext < _maximumTokens.length; currentContext++) {
        counts.setRange(
          currentContext * stride,
          currentContext * stride + _countsStride,
          _counts,
          currentContext * _countsStride,
        );
      }
    }
    final Int32List maximumTokens = Int32List(contexts)..fillRange(_maximumTokens.length, contexts, -1);
    maximumTokens.setRange(0, _maximumTokens.length, _maximumTokens);
    _counts = counts;
    _countsStride = stride;
    _maximumTokens = maximumTokens;
  }

  /// Exact-code-length estimate of the payload size in bits: the actual
  /// Huffman lengths are computed per cluster, so the prefix-coding
  /// 1-bit-per-symbol floor is accounted for (Shannon entropy is not a
  /// safe proxy for highly skewed histograms).
  double estimatedBits() {
    double bits = _extraBits;
    for (final List<int> hist in _histograms) {
      final List<int>? codeLengths = _safeLengths(hist);
      if (codeLengths == null) {
        continue; // zero-bit symbols
      }
      for (var s = 0; s < hist.length; s++) {
        bits += hist[s] * codeLengths[s];
      }
      // Rough per-cluster header cost.
      bits += 8.0 * hist.length.clamp(4, 64) + 40;
    }
    return bits;
  }

  /// Per-cluster Huffman code length for every token (0 for unused/
  /// zero-bit-symbol clusters) — an auxiliary table for cheap rate
  /// estimation elsewhere (e.g. a per-block rate-distortion decision
  /// scoring several quantization candidates against an already-built,
  /// frozen histogram), not part of the real bitstream. Uses the exact
  /// same length-limited Huffman construction [estimatedBits] and the
  /// real prefix-code writer already use, so it inherits their
  /// 1-bit-per-symbol floor correctness (Shannon entropy is not safe
  /// here — see [estimatedBits]'s doc comment).
  List<List<int>> tokenBitLengths() => [for (final hist in _histograms) _safeLengths(hist) ?? List<int>.filled(hist.length, 0)];

  /// Length-limited Huffman lengths for [hist], or null when the cluster
  /// has 0 or 1 used symbols (no real code needed — [estimatedBits] and
  /// [tokenBitLengths] both treat that as a zero-bit-per-symbol cluster).
  List<int>? _safeLengths(List<int> hist) {
    var used = 0;
    var total = 0;
    for (final count in hist) {
      if (count > 0) {
        used++;
      }
      total += count;
    }
    if (total == 0 || used <= 1) {
      return null;
    }
    return huffmanLengths(hist, 15);
  }

  // --- ANS (rANS) mode ---

  /// Whether every cluster's token alphabet fits in 2^8 = 256 symbols, the
  /// most an ANS distribution can address (logAlphabetSize <= 8).
  bool get ansViable {
    for (final int size in _alphabetSizes) {
      if (size > 256) {
        return false;
      }
    }
    return true;
  }

  /// Dimensions or allocation size of ANS log alphabet in the entropy-code set.
  int get _ansLogAlphabetSize {
    var maxSize = 1;
    for (final int size in _alphabetSizes) {
      if (size > maxSize) {
        maxSize = size;
      }
    }
    var log = 5;
    while ((1 << log) < maxSize) {
      log++;
    }
    return log;
  }

  /// Coded-size estimate for the ANS path: fractional bits per token
  /// (the whole point of ANS) plus the extra bits and a header estimate.
  double ansEstimatedBits() {
    double bits = _extraBits;
    for (final List<int> hist in _histograms) {
      var total = 0;
      for (final count in hist) {
        total += count;
      }
      if (total == 0) {
        continue;
      }
      final Int32List frequencies = normalizeFrequencies(hist, hist.length);
      for (var s = 0; s < hist.length; s++) {
        if (hist[s] > 0) {
          bits += hist[s] * (math.log(4096 / frequencies[s]) / math.ln2);
        }
      }
      bits += 12.0 * hist.length + 40; // distribution header
    }
    return bits;
  }

  /// Writes the ANS distribution header and prepares the alias tables.
  void writeAnsHeader(BitWriter w) {
    _ansLogarithm = _ansLogAlphabetSize;
    final int clusters = _clusterCount;
    w.writeBool(usesLz77);
    if (usesLz77) {
      w.writeU32(lz77MinSymbol, 224, 0, 512, 0, 4096, 0, 8, 15);
      w.writeU32(lz77MinLength, 3, 0, 4, 0, 5, 2, 9, 8);
      w.writeBits(lz77LengthConfiguration.splitExponent, ceilLog1p(8));
      if (lz77LengthConfiguration.splitExponent != 8) {
        w.writeBits(lz77LengthConfiguration.msbInToken, ceilLog1p(lz77LengthConfiguration.splitExponent));
        w.writeBits(lz77LengthConfiguration.lsbInToken, ceilLog1p(lz77LengthConfiguration.splitExponent - lz77LengthConfiguration.msbInToken));
      }
    }
    _writeClusterMap(w, clusters);
    w.writeBool(false); // use_prefix_code = false (ANS)
    w.writeBits(_ansLogarithm - 5, 2);
    for (var c = 0; c < clusters; c++) {
      w.writeBits(config.splitExponent, ceilLog1p(_ansLogarithm));
      if (config.splitExponent != _ansLogarithm) {
        w.writeBits(config.msbInToken, ceilLog1p(config.splitExponent));
        w.writeBits(config.lsbInToken, ceilLog1p(config.splitExponent - config.msbInToken));
      }
    }
    _ansTables = [];
    for (var c = 0; c < clusters; c++) {
      final int declared = _histograms[c].length < 3 ? 3 : _histograms[c].length;
      final counts = List<int>.filled(declared, 0);
      for (var s = 0; s < _histograms[c].length; s++) {
        counts[s] = _histograms[c][s];
      }
      final Int32List frequencies = normalizeFrequencies(counts, declared);
      writeAnsDistribution(w, frequencies);
      _ansTables!.add(AnsAliasTable(frequencies: frequencies, logAlphabetSize: _ansLogarithm));
    }
  }

  /// Encodes one section as a fresh rANS stream over the shared tables.
  void encodeAnsSection(BitWriter w, List<int> contexts, List<int> values) {
    if (config.splitExponent == 4 && config.msbInToken == 1 && config.lsbInToken == 0) {
      final AnsEncoderH410 encoder = AnsEncoderH410(aliasTables: _ansTables!, expectedSymbols: values.length);
      for (int index = values.length - 1; index >= 0; index--) {
        encoder.prependValue(contexts[index], values[index]);
      }
      encoder.finish(w);
      return;
    }
    final AnsEncoder encoder = AnsEncoder(aliasTables: _ansTables!, expectedSymbols: values.length);
    for (int index = values.length - 1; index >= 0; index--) {
      final (int token, int extraBitCount, int extra) = tokenizeHybrid(config, values[index]);
      encoder.prependSymbol(contexts[index], token, extra: extra, extraBits: extraBitCount);
    }
    encoder.finish(w);
  }

  /// Encodes one h410 section whose contexts are constant over compact runs.
  void encodeAnsSectionRuns(BitWriter writer, Int32List runContexts, Int32List runEnds, List<int> values) {
    if (config.splitExponent != 4 || config.msbInToken != 1 || config.lsbInToken != 0) {
      throw StateError('Compact context runs require the h410 configuration.');
    }
    if (runContexts.length != runEnds.length || (runEnds.isEmpty ? values.isNotEmpty : runEnds.last != values.length)) {
      throw ArgumentError('Context runs do not cover the entropy section.');
    }
    final AnsEncoderH410 encoder = AnsEncoderH410(aliasTables: _ansTables!, expectedSymbols: values.length);
    for (int run = runContexts.length - 1; run >= 0; run--) {
      final int start = run == 0 ? 0 : runEnds[run - 1];
      for (int index = runEnds[run] - 1; index >= start; index--) {
        encoder.prependValue(runContexts[run], values[index]);
      }
    }
    encoder.finish(writer);
  }

  /// Encodes one LZ77 op stream as a fresh rANS stream. A match emits a
  /// length symbol (in its pixel cluster, offset by [lz77MinSymbol]) then a
  /// distance symbol (in the distance cluster), each with its raw extra
  /// bits — the exact read order in EntropyStream.readSymbol.
  void encodeAnsLz77Section(BitWriter w, Lz77Operations ops) {
    final AnsEncoder encoder = AnsEncoder(aliasTables: _ansTables!, expectedSymbols: ops.operationKinds.length);
    for (int index = ops.operationKinds.length - 1; index >= 0; index--) {
      if (ops.operationKinds[index] == 0) {
        final (int token, int extraBitCount, int extra) = tokenizeHybrid(config, ops.literalValuesOrMatchLengths[index]);
        encoder.prependSymbol(ops.contexts[index], token, extra: extra, extraBits: extraBitCount);
      } else {
        final (int distanceToken, int distanceExtraBitCount, int distanceExtra) = tokenizeHybrid(config, ops.matchDistances[index] + 119);
        encoder.prependSymbol(contextCount, distanceToken, extra: distanceExtra, extraBits: distanceExtraBitCount);
        final (int lengthToken, int lengthExtraBitCount, int lengthExtra) = tokenizeHybrid(
          lz77LengthConfiguration,
          ops.literalValuesOrMatchLengths[index] - lz77MinLength,
        );
        encoder.prependSymbol(ops.contexts[index], lz77MinSymbol + lengthToken, extra: lengthExtra, extraBits: lengthExtraBitCount);
      }
    }
    encoder.finish(w);
  }

  /// Finalizes histograms.
  void _finishHistograms(int clusters) {
    for (var c = 0; c < clusters; c++) {
      final int maxToken = c < _maximumTokens.length ? _maximumTokens[c] : -1;
      final int size = maxToken < 0 ? 1 : maxToken + 1;
      _alphabetSizes.add(size);
      final hist = List<int>.filled(size, 0);
      final int base = c * _countsStride;
      for (var t = 0; t <= maxToken; t++) {
        hist[t] = _counts[base + t];
      }
      _histograms.add(hist);
      _codes.add(const []);
      _codeLengths.add(const []);
    }
  }

  /// Writes an identity cluster map for [clusters] contexts: the simple
  /// fixed-width form for up to 8 clusters, otherwise a nested entropy
  /// stream over the cluster ids (the decoder's complex path, no MTF).
  static void _writeClusterMap(BitWriter w, int clusters) {
    if (clusters <= 1) {
      return;
    }
    final int nbits = ceilLog1p(clusters - 1);
    if (nbits <= 3) {
      w.writeBool(true); // simple
      w.writeBits(nbits, 2);
      for (var i = 0; i < clusters; i++) {
        w.writeBits(i, nbits);
      }
      return;
    }
    w.writeBool(false); // complex
    w.writeBool(false); // use_mtf = false
    final nested = EntropyEncoder(contextCount: 1);
    for (var i = 0; i < clusters; i++) {
      nested.write(0, i);
    }
    nested.finalize(w);
  }

  /// Writes a general cluster map: `clusterMap[i]` is the output cluster
  /// for input context id `i` (need not be identity, and need not use
  /// every input id — unreachable ids can map anywhere). Mirrors the
  /// decoder's `EntropyStream.readClusterMap`'s two encodings: the
  /// fixed-width "simple" form when `numClusters <= 8`, otherwise a nested
  /// entropy stream over the per-entry cluster ids (which Huffman-codes
  /// away the cost of ids that repeat a lot, e.g. every unreachable
  /// context id sharing one arbitrary fallback cluster).
  static void _writeGeneralClusterMap(BitWriter w, List<int> clusterMap, int numClusters) {
    if (clusterMap.length <= 1) {
      return;
    }
    final int nbits = ceilLog1p(numClusters - 1);
    if (nbits <= 3) {
      w.writeBool(true); // simple
      w.writeBits(nbits, 2);
      for (final c in clusterMap) {
        w.writeBits(c, nbits);
      }
      return;
    }
    w.writeBool(false); // complex
    w.writeBool(false); // use_mtf = false
    final nested = EntropyEncoder(contextCount: 1);
    for (final c in clusterMap) {
      nested.write(0, c);
    }
    nested.finalize(w);
  }

  /// Writes the distribution header (mirror of `EntropyStream.read`).
  /// [clusterMap], when given, writes a general (possibly non-identity)
  /// cluster map via [_writeGeneralClusterMap] instead of the default
  /// identity map; `clusterMap[i]` must be a valid cluster index for every
  /// input context id `i` this stream's decoder-side domain size expects.
  void writeHeader(BitWriter w, {List<int>? clusterMap}) {
    w.writeBool(usesLz77);
    if (usesLz77) {
      w.writeU32(lz77MinSymbol, 224, 0, 512, 0, 4096, 0, 8, 15);
      w.writeU32(lz77MinLength, 3, 0, 4, 0, 5, 2, 9, 8);
      // lz_length_config, read with logAlphabetSize 8.
      w.writeBits(lz77LengthConfiguration.splitExponent, ceilLog1p(8));
      if (lz77LengthConfiguration.splitExponent != 8) {
        w.writeBits(lz77LengthConfiguration.msbInToken, ceilLog1p(lz77LengthConfiguration.splitExponent));
        w.writeBits(lz77LengthConfiguration.lsbInToken, ceilLog1p(lz77LengthConfiguration.splitExponent - lz77LengthConfiguration.msbInToken));
      }
    }
    final int clusters = _clusterCount;
    if (clusterMap != null) {
      _writeGeneralClusterMap(w, clusterMap, clusters);
    } else {
      _writeClusterMap(w, clusters);
    }
    w.writeBool(true); // use_prefix_code
    for (var c = 0; c < clusters; c++) {
      w.writeBits(config.splitExponent, ceilLog1p(15));
      if (config.splitExponent != 15) {
        w.writeBits(config.msbInToken, ceilLog1p(config.splitExponent));
        w.writeBits(config.lsbInToken, ceilLog1p(config.splitExponent - config.msbInToken));
      }
    }
    for (var c = 0; c < clusters; c++) {
      final int size = _alphabetSizes[c];
      if (size == 1) {
        w.writeBool(false);
      } else {
        w.writeBool(true);
        final int n = (size - 1).bitLength - 1;
        w.writeBits(n, 4);
        w.writeBits(size - 1 - (1 << n), n);
      }
    }
    for (var c = 0; c < clusters; c++) {
      if (_alphabetSizes[c] == 1) {
        _codes[c] = const [0];
        _codeLengths[c] = const [0];
        continue;
      }
      final (List<int> cc, List<int> ll) = writePrefixCode(w, _histograms[c], _alphabetSizes[c]);
      _codes[c] = cc;
      _codeLengths[c] = ll;
    }
  }

  /// Emits one LZ77 op stream.
  void writeOps(BitWriter w, Lz77Operations ops) {
    assert(usesLz77, 'LZ77 operations require an LZ77 entropy stream.');
    for (var i = 0; i < ops.operationKinds.length; i++) {
      if (ops.operationKinds[i] == 0) {
        writeToken(w, ops.contexts[i], ops.literalValuesOrMatchLengths[i]);
      } else {
        final (int t, int nbits, int extra) = tokenizeHybrid(lz77LengthConfiguration, ops.literalValuesOrMatchLengths[i] - lz77MinLength);
        final int sym = lz77MinSymbol + t;
        w.writeBits(_codes[ops.contexts[i]][sym], _codeLengths[ops.contexts[i]][sym]);
        if (nbits > 0) {
          w.writeBits(extra, nbits);
        }
        writeToken(w, contextCount, ops.matchDistances[i] + 119);
      }
    }
  }

  /// Emits one value (must be called only after [writeHeader]).
  void writeToken(BitWriter w, int context, int value) {
    final (int token, int extraBits, int extra) = tokenizeHybrid(config, value);
    w.writeBits(_codes[context][token], _codeLengths[context][token]);
    if (extraBits > 0) {
      w.writeBits(extra, extraBits);
    }
  }
}

/// Buffers (context, value) tokens and serializes header + payload into a
/// single writer (convenience over [EntropyCodes]).
final class EntropyEncoder {
  /// Number of entropy contexts.
  final int contextCount;

  /// Hybrid-integer representation used to tokenize queued values.
  final HybridIntegerConfig config;

  /// Entropy context selected for each queued value.
  final List<int> _contexts = [];

  /// Non-negative values queued in decode order.
  final List<int> _values = [];

  /// Creates a buffered entropy encoder for [contextCount] contexts.
  EntropyEncoder({
    required this.contextCount,
    this.config = const HybridIntegerConfig(
      splitExponent: 4,
      msbInToken: 1,
      lsbInToken: 0,
    ),
  });

  /// Queues one [value] under its entropy [context].
  void write(int context, int value) {
    assert(context >= 0 && context < contextCount, 'The entropy context is outside the configured range.');
    assert(value >= 0, 'Entropy values cannot be negative.');
    _contexts.add(context);
    _values.add(value);
  }

  /// Finalizes the accumulated state.
  void finalize(BitWriter w) {
    final codes = EntropyCodes.build(contextCount: contextCount, contexts: _contexts, values: _values, config: config);
    codes.writeHeader(w);
    for (var i = 0; i < _values.length; i++) {
      codes.writeToken(w, _contexts[i], _values[i]);
    }
  }
}
