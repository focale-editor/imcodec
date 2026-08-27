import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/symbol_distribution.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/vlc_table.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The fixed 4-bit level-0 table used to read code lengths of the level-1
/// code-length code (Brotli-style).
final _level0Table = VlcTable.fromEntries(
  bits: 4,
  symbols: const [
    0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5, //
  ],
  lengths: const [
    2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4, //
  ],
);

/// Mapping used for codelen.
const _codeLengthOrder = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15];

/// A Brotli-style prefix-code symbol distribution.
final class PrefixSymbolDistribution extends SymbolDistribution {
  /// Variable-length-code lookup table for multi-symbol distributions.
  VlcTable? _table;

  /// Only symbol emitted by a single-symbol distribution.
  int _defaultSymbol = 0;

  /// Creates a prefix symbol distribution.
  PrefixSymbolDistribution({
    required BitReader reader,
    required int alphabetSize,
  }) {
    this.alphabetSize = alphabetSize;
    logAlphabetSize = ceilLog1p(alphabetSize - 1);

    if (alphabetSize == 1) {
      _table = null;
      _defaultSymbol = 0;
      return;
    }
    final int hskip = reader.readBits(2);
    if (hskip == 1) {
      _populateSimple(reader);
    } else {
      _populateComplex(reader, hskip);
    }
  }

  /// Populates simple.
  void _populateSimple(BitReader reader) {
    final symbols = List<int>.filled(4, 0);
    final int nsym = 1 + reader.readBits(2);
    for (var i = 0; i < nsym; i++) {
      symbols[i] = reader.readBits(logAlphabetSize);
    }
    final bool treeSelect = nsym == 4 && reader.readBool();
    List<int> lens;
    int bits;
    switch (nsym) {
      case 1:
        _table = null;
        _defaultSymbol = symbols[0];
        return;
      case 2:
        bits = 1;
        lens = const [1, 1, 0, 0];
        if (symbols[0] > symbols[1]) {
          final int temp = symbols[1];
          symbols[1] = symbols[0];
          symbols[0] = temp;
        }
      case 3:
        bits = 2;
        lens = const [1, 2, 2, 0];
        if (symbols[1] > symbols[2]) {
          final int temp = symbols[2];
          symbols[2] = symbols[1];
          symbols[1] = temp;
        }
      default:
        if (treeSelect) {
          bits = 3;
          lens = const [1, 2, 3, 3];
          if (symbols[2] > symbols[3]) {
            final int temp = symbols[3];
            symbols[3] = symbols[2];
            symbols[2] = temp;
          }
        } else {
          bits = 2;
          lens = const [2, 2, 2, 2];
          symbols.sort();
        }
    }
    _table = VlcTable.canonical(bits: bits, lengths: lens, symbols: symbols);
  }

  /// Populates complex.
  void _populateComplex(BitReader reader, int hskip) {
    final level1Lengths = List<int>.filled(18, 0);
    final level1Codecounts = List<int>.filled(19, 0);
    level1Codecounts[0] = hskip;

    var totalCode = 0;
    var numCodes = 0;
    for (var i = hskip; i < 18; i++) {
      final int code = level1Lengths[_codeLengthOrder[i]] = _level0Table.readSymbol(reader);
      level1Codecounts[code]++;
      if (code != 0) {
        totalCode += 32 >> code;
        numCodes++;
      }
      if (totalCode >= 32) {
        level1Codecounts[0] += 17 - i;
        break;
      }
    }
    if (totalCode != 32 && numCodes >= 2 || numCodes < 1) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid level 1 prefix codes');
    }
    for (var i = 1; i < 19; i++) {
      level1Codecounts[i] += level1Codecounts[i - 1];
    }
    final level1LengthsScrambled = List<int>.filled(18, 0);
    final level1Symbols = List<int>.filled(18, 0);
    for (var i = 17; i >= 0; i--) {
      final int index = --level1Codecounts[level1Lengths[i]];
      if (index < 0 || index >= 18) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid level 1 prefix code');
      }
      level1LengthsScrambled[index] = level1Lengths[i];
      level1Symbols[index] = i;
    }

    final VlcTable level1Table;
    if (numCodes == 1) {
      level1Table = VlcTable.fromEntries(bits: 0, symbols: [level1Symbols[17]], lengths: [0]);
    } else {
      level1Table = VlcTable.canonical(bits: 5, lengths: level1LengthsScrambled, symbols: level1Symbols);
    }

    totalCode = 0;
    var prevRepeatCount = 0;
    var prevZeroCount = 0;
    final level2Lengths = List<int>.filled(alphabetSize, 0);
    final level2Symbols = List<int>.filled(alphabetSize, 0);
    final level2Counts = List<int>.filled(alphabetSize + 1, 0);
    var prev = 8;
    for (var i = 0; i < alphabetSize; i++) {
      final int code = level1Table.readSymbol(reader);
      if (code == 16) {
        int extra = 3 + reader.readBits(2);
        if (prevRepeatCount > 0) {
          extra = 4 * (prevRepeatCount - 2) - prevRepeatCount + extra;
        }
        if (i + extra > alphabetSize) {
          throw const JpegXlInvalidBitstreamException(message: 'level 2 repeat overflows alphabet');
        }
        if (prev > alphabetSize) {
          throw const JpegXlInvalidBitstreamException(message: 'level 2 repeat length exceeds alphabet');
        }
        for (var j = 0; j < extra; j++) {
          level2Lengths[i + j] = prev;
        }
        totalCode += (32768 >> prev) * extra;
        i += extra - 1;
        prevRepeatCount += extra;
        prevZeroCount = 0;
        level2Counts[prev] += extra;
      } else if (code == 17) {
        int extra = 3 + reader.readBits(3);
        if (prevZeroCount > 0) {
          extra = 8 * (prevZeroCount - 2) - prevZeroCount + extra;
        }
        i += extra - 1;
        prevRepeatCount = 0;
        prevZeroCount += extra;
        level2Counts[0] += extra;
      } else {
        // A code length that cannot fit this alphabet is invalid (and would
        // index past level2Counts, which has alphabetSize + 1 buckets).
        if (code > alphabetSize) {
          throw const JpegXlInvalidBitstreamException(message: 'prefix code length exceeds alphabet');
        }
        level2Lengths[i] = code;
        prevRepeatCount = 0;
        prevZeroCount = 0;
        if (code != 0) {
          totalCode += 32768 >> code;
          prev = code;
        }
        level2Counts[code]++;
      }
      if (totalCode >= 32768) {
        level2Counts[0] += alphabetSize - i - 1;
        break;
      }
    }
    if (totalCode != 32768 && level2Counts[0] < alphabetSize - 1) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid level 2 prefix codes');
    }
    for (var i = 1; i <= alphabetSize; i++) {
      level2Counts[i] += level2Counts[i - 1];
    }
    final level2LengthsScrambled = List<int>.filled(alphabetSize, 0);
    for (int i = alphabetSize - 1; i >= 0; i--) {
      final int index = --level2Counts[level2Lengths[i]];
      if (index < 0 || index >= alphabetSize) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid level 2 prefix code');
      }
      level2LengthsScrambled[index] = level2Lengths[i];
      level2Symbols[index] = i;
    }
    _table = VlcTable.canonical(bits: 15, lengths: level2LengthsScrambled, symbols: level2Symbols);
  }

  @override
  int readSymbol(BitReader reader, AnsState state) {
    final VlcTable? table = _table;
    if (table == null) {
      return _defaultSymbol;
    }
    return table.readSymbol(reader);
  }
}
