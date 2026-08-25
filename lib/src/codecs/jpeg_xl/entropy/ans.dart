import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_tables.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/symbol_distribution.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/vlc_table.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Fixed 7-bit prefix table for reading ANS distribution log counts.
final _distPrefixTable = VlcTable.fromEntries(bits: 7, symbols: ansDistPrefixSymbols, lengths: ansDistPrefixLengths);

/// An alias-mapped rANS symbol distribution (12-bit precision).
final class AnsSymbolDistribution extends SymbolDistribution {
  /// Stores the frequencies state used internally by the JPEG XL codec.
  ///
  late final Int32List _frequencies;

  /// Stores the cutoffs state used internally by the JPEG XL codec.
  ///
  late final Int32List _cutoffs;

  /// Stores the symbols state used internally by the JPEG XL codec.
  ///
  late final Int32List _symbols;

  /// Stores the offsets state used internally by the JPEG XL codec.
  ///
  late final Int32List _offsets;

  /// Stores the bucket mask state used internally by the JPEG XL codec.
  ///
  late final int _bucketMask;

  /// Creates Ans symbol distribution data for JPEG XL processing.
  ///
  AnsSymbolDistribution({
    required BitReader reader,
    required int logAlphabetSize,
  }) {
    this.logAlphabetSize = logAlphabetSize;
    var uniqPos = -1;
    if (reader.readBool()) {
      // Simple distribution: one or two spikes.
      if (reader.readBool()) {
        final int v1 = reader.readU8();
        final int v2 = reader.readU8();
        if (v1 == v2) {
          throw const JpegXlInvalidBitstreamException(message: 'overlapping dual peak distribution');
        }
        alphabetSize = 1 + (v1 > v2 ? v1 : v2);
        _checkAlphabetSize();
        _frequencies = Int32List(alphabetSize);
        _frequencies[v1] = reader.readBits(12);
        _frequencies[v2] = (1 << 12) - _frequencies[v1];
        if (_frequencies[v1] == 0) {
          uniqPos = v2;
        }
      } else {
        final int x = reader.readU8();
        alphabetSize = 1 + x;
        _frequencies = Int32List(alphabetSize);
        _frequencies[x] = 1 << 12;
        uniqPos = x;
      }
    } else if (reader.readBool()) {
      // Flat distribution.
      alphabetSize = 1 + reader.readU8();
      _checkAlphabetSize();
      if (alphabetSize == 1) {
        uniqPos = 0;
      }
      _frequencies = Int32List(alphabetSize);
      for (var i = 0; i < alphabetSize; i++) {
        _frequencies[i] = (1 << 12) ~/ alphabetSize;
      }
      for (var i = 0; i < (1 << 12) % alphabetSize; i++) {
        _frequencies[i]++;
      }
    } else {
      // General distribution: log counts + refinement bits.
      var len = 0;
      while (len < 3) {
        if (!reader.readBool()) {
          break;
        }
        len++;
      }
      final int shift = (reader.readBits(len) | (1 << len)) - 1;
      if (shift > 13) {
        throw const JpegXlInvalidBitstreamException(message: 'ANS shift > 13');
      }
      alphabetSize = 3 + reader.readU8();
      _checkAlphabetSize();
      _frequencies = Int32List(alphabetSize);
      final logCounts = Int32List(alphabetSize);
      final same = Int32List(alphabetSize);
      var omitLog = -1;
      var omitPos = -1;
      for (var i = 0; i < alphabetSize; i++) {
        logCounts[i] = _distPrefixTable.getVlc(reader);
        if (logCounts[i] == 13) {
          final int rle = reader.readU8();
          same[i] = rle + 5;
          i += rle + 3;
          continue;
        }
        if (logCounts[i] > omitLog) {
          omitLog = logCounts[i];
          omitPos = i;
        }
      }
      if (omitPos < 0 || omitPos + 1 < alphabetSize && logCounts[omitPos + 1] == 13) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid omitPos');
      }
      var totalCount = 0;
      var numSame = 0;
      var prev = 0;
      for (var i = 0; i < alphabetSize; i++) {
        if (same[i] != 0) {
          numSame = same[i] - 1;
          prev = i > 0 ? _frequencies[i - 1] : 0;
        }
        if (numSame != 0) {
          _frequencies[i] = prev;
          numSame--;
        } else {
          if (i == omitPos || logCounts[i] == 0) {
            continue;
          }
          if (logCounts[i] == 1) {
            _frequencies[i] = 1;
          } else {
            int bitcount = shift - ((12 - logCounts[i] + 1) >> 1);
            if (bitcount < 0) {
              bitcount = 0;
            }
            if (bitcount > logCounts[i] - 1) {
              bitcount = logCounts[i] - 1;
            }
            _frequencies[i] = (1 << (logCounts[i] - 1)) + (reader.readBits(bitcount) << (logCounts[i] - 1 - bitcount));
          }
        }
        totalCount += _frequencies[i];
      }
      _frequencies[omitPos] = (1 << 12) - totalCount;
      if (_frequencies[omitPos] < 0) {
        throw const JpegXlInvalidBitstreamException(message: 'ANS frequencies exceed 1 << 12');
      }
    }
    _generateAliasMapping(uniqPos);
  }

  /// Checks alphabet size.
  ///
  void _checkAlphabetSize() {
    if (alphabetSize > 1 << logAlphabetSize) {
      throw JpegXlInvalidBitstreamException(message: 'illegal alphabet size: $alphabetSize');
    }
  }

  @override
  @pragma('vm:prefer-inline')
  int readSymbol(BitReader reader, AnsState stateObj) {
    int state = stateObj.hasState ? stateObj.state : reader.readBits(32);
    final int index = state & 0xFFF;
    final int i = index >> logBucketSize;
    final int pos = index & _bucketMask;
    final bool greater = pos >= _cutoffs[i];
    final int symbol = greater ? _symbols[i] : i;
    final int offset = greater ? _offsets[i] + pos : pos;
    state = _frequencies[symbol] * (state >> 12) + offset;
    if (state < 1 << 16) {
      state = (state << 16) | reader.readBits(16);
    }
    stateObj.state = state;
    return symbol;
  }

  /// Processes the generate alias mapping data used by the JPEG XL codec.
  ///
  void _generateAliasMapping(int uniqPos) {
    logBucketSize = 12 - logAlphabetSize;
    _bucketMask = (1 << logBucketSize) - 1;
    final int bucketSize = 1 << logBucketSize;
    final int tableSize = 1 << logAlphabetSize;

    _symbols = Int32List(tableSize);
    _cutoffs = Int32List(tableSize);
    _offsets = Int32List(tableSize);

    if (uniqPos >= 0) {
      for (var i = 0; i < tableSize; i++) {
        _symbols[i] = uniqPos;
        _offsets[i] = i * bucketSize;
        _cutoffs[i] = 0;
      }
      return;
    }

    final overfull = <int>[];
    final underfull = <int>[];
    for (var i = 0; i < alphabetSize; i++) {
      _cutoffs[i] = _frequencies[i];
      _symbols[i] = i;
      if (_cutoffs[i] > bucketSize) {
        overfull.add(i);
      } else if (_cutoffs[i] < bucketSize) {
        underfull.add(i);
      }
    }
    for (int i = alphabetSize; i < tableSize; i++) {
      underfull.add(i);
    }
    while (overfull.isNotEmpty) {
      final int u = underfull.removeLast();
      final int o = overfull.removeLast();
      final int by = bucketSize - _cutoffs[u];
      _cutoffs[o] -= by;
      _symbols[u] = o;
      _offsets[u] = _cutoffs[o];
      if (_cutoffs[o] < bucketSize) {
        underfull.add(o);
      } else if (_cutoffs[o] > bucketSize) {
        overfull.add(o);
      }
    }
    for (var i = 0; i < tableSize; i++) {
      if (_cutoffs[i] == bucketSize) {
        _symbols[i] = i;
        _offsets[i] = 0;
        _cutoffs[i] = 0;
      } else {
        _offsets[i] -= _cutoffs[i];
      }
    }
  }
}
