import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/ans.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_tables.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/hybrid_uint.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/prefix.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/symbol_distribution.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// An entropy-coded symbol stream: clustered distributions (prefix or ANS),
/// hybrid-integer token expansion, and an optional LZ77 window.
final class EntropyStream {
  /// Whether entropy coding uses LZ77 references.
  late final bool usesLz77;

  /// First entropy symbol reserved for an LZ77 match.
  int _lz77MinSymbol = 0;

  /// Length of lz 77 min in the entropy stream.
  int _lz77MinLength = 0;

  /// Hybrid-integer configuration used for LZ77 match lengths.
  HybridIntegerConfig? _lz77LengthConfig;

  /// Mapping used to resolve cluster in the entropy stream.
  late final Int32List _clusterMap;

  /// Symbol distributions selected through [_clusterMap].
  late final List<SymbolDistribution> _distributions;

  /// Dimensions or allocation size of log alphabet in the entropy stream.
  late final int _logAlphabetSize;

  /// Circular history buffer used by LZ77 back-references.
  Int32List? _window;

  /// Number of symbols remaining in the active LZ77 back-reference.
  int _remainingCopyCount = 0;

  /// Source position of the active LZ77 back-reference.
  int _copyPosition = 0;

  /// Number of decoded symbols written to the history window.
  int _decodedSymbolCount = 0;

  /// Range-ANS state shared by the stream's symbol distributions.
  final AnsState _ansState = AnsState();

  /// Reads this structure from the bitstream.
  EntropyStream.read({
    required BitReader reader,
    required int distributionCount,
  }) : this._(
         reader: reader,
         distributionCount: distributionCount,
         disallowLz77: false,
       );

  /// Shares the parsed distributions of [other] but with fresh LZ77/ANS
  /// decoding state (used when the same histograms apply to a new section).
  EntropyStream.clone({
    required EntropyStream other,
  }) : usesLz77 = other.usesLz77,
       _lz77MinSymbol = other._lz77MinSymbol,
       _lz77MinLength = other._lz77MinLength,
       _lz77LengthConfig = other._lz77LengthConfig,
       _clusterMap = other._clusterMap,
       _distributions = other._distributions,
       _logAlphabetSize = other._logAlphabetSize {
    if (usesLz77) {
      _window = Int32List(1 << 20);
    }
  }

  /// Creates an entropy stream.
  EntropyStream._({
    required BitReader reader,
    required int distributionCount,
    required bool disallowLz77,
  }) {
    int decodedDistributionCount = distributionCount;
    if (decodedDistributionCount <= 0) {
      throw ArgumentError('distributionCount must be positive');
    }
    usesLz77 = reader.readBool();
    if (usesLz77) {
      if (disallowLz77) {
        throw const JpegXlInvalidBitstreamException(message: 'nested distributions cannot use LZ77');
      }
      _lz77MinSymbol = reader.readU32(224, 0, 512, 0, 4096, 0, 8, 15);
      _lz77MinLength = reader.readU32(3, 0, 4, 0, 5, 2, 9, 8);
      decodedDistributionCount++;
      _lz77LengthConfig = HybridIntegerConfig.read(reader: reader, logAlphabetSize: 8);
      _window = Int32List(1 << 20);
    }

    _clusterMap = Int32List(decodedDistributionCount);
    final int clusterCount = readClusterMap(reader, _clusterMap, decodedDistributionCount);

    final bool prefixCodes = reader.readBool();
    _logAlphabetSize = prefixCodes ? 15 : 5 + reader.readBits(2);
    final configs = List<HybridIntegerConfig>.generate(clusterCount, (_) => HybridIntegerConfig.read(reader: reader, logAlphabetSize: _logAlphabetSize));

    if (prefixCodes) {
      final alphabetSizes = List<int>.generate(clusterCount, (_) {
        if (!reader.readBool()) {
          return 1;
        }
        final int n = reader.readBits(4);
        return 1 + (1 << n) + reader.readBits(n);
      });
      _distributions = List<SymbolDistribution>.generate(clusterCount, (i) => PrefixSymbolDistribution(reader: reader, alphabetSize: alphabetSizes[i]));
    } else {
      _distributions = List<SymbolDistribution>.generate(clusterCount, (_) => AnsSymbolDistribution(reader: reader, logAlphabetSize: _logAlphabetSize));
    }
    for (var i = 0; i < clusterCount; i++) {
      _distributions[i].config = configs[i];
    }
  }

  /// Reads a cluster map of `clusterMap.length` entries; returns the number
  /// of clusters.
  static int readClusterMap(BitReader reader, Int32List clusterMap, int maxClusters) {
    final int distributionCount = clusterMap.length;
    if (distributionCount == 1) {
      clusterMap[0] = 0;
    } else if (reader.readBool()) {
      // Simple clustering.
      final int nbits = reader.readBits(2);
      for (var i = 0; i < distributionCount; i++) {
        clusterMap[i] = reader.readBits(nbits);
      }
    } else {
      final bool usesMoveToFront = reader.readBool();
      final nested = EntropyStream._(reader: reader, distributionCount: 1, disallowLz77: distributionCount <= 2);
      for (var i = 0; i < distributionCount; i++) {
        clusterMap[i] = nested.readSymbol(reader, 0);
      }
      if (!nested.validateFinalState()) {
        throw const JpegXlInvalidBitstreamException(message: 'nested cluster-map distribution');
      }
      if (usesMoveToFront) {
        final moveToFront = Int32List(256);
        for (var i = 0; i < 256; i++) {
          moveToFront[i] = i;
        }
        for (var i = 0; i < distributionCount; i++) {
          final int index = clusterMap[i];
          if (index > 255) {
            throw const JpegXlInvalidBitstreamException(message: 'MTF index out of range');
          }
          clusterMap[i] = moveToFront[index];
          if (index != 0) {
            final int value = moveToFront[index];
            for (var j = index; j > 0; j--) {
              moveToFront[j] = moveToFront[j - 1];
            }
            moveToFront[0] = value;
          }
        }
      }
    }
    var clusterCount = 0;
    for (var i = 0; i < distributionCount; i++) {
      if (clusterMap[i] >= clusterCount) {
        clusterCount = clusterMap[i] + 1;
      }
    }
    if (clusterCount > maxClusters) {
      throw const JpegXlInvalidBitstreamException(message: 'too many clusters');
    }
    return clusterCount;
  }

  /// Resets the accumulated state.
  void reset() {
    _remainingCopyCount = 0;
    _ansState.reset();
  }

  /// After a section is fully read, the ANS state must sit at the canonical
  /// final value (or never have been initialized at all).
  bool validateFinalState() => !_ansState.hasState || _ansState.state == 0x130000;

  /// Reads one entropy-coded symbol.
  int readSymbol(BitReader reader, int context, {int distanceMultiplier = 0}) {
    if (_remainingCopyCount > 0) {
      final Int32List window = _window!;
      final int hybridInt = window[_copyPosition++ & 0xFFFFF];
      _remainingCopyCount--;
      window[_decodedSymbolCount++ & 0xFFFFF] = hybridInt;
      return hybridInt;
    }

    if (context < 0 || context >= _clusterMap.length) {
      throw const JpegXlInvalidBitstreamException(message: 'entropy context out of range');
    }
    final int cluster = _clusterMap[context];
    final SymbolDistribution dist = _distributions[cluster];
    int token = dist.readSymbol(reader, _ansState);

    if (usesLz77 && token >= _lz77MinSymbol) {
      final SymbolDistribution lz77dist = _distributions[_clusterMap[_clusterMap.length - 1]];
      _remainingCopyCount = _lz77MinLength + _readHybridInteger(reader, _lz77LengthConfig!, token - _lz77MinSymbol);
      token = lz77dist.readSymbol(reader, _ansState);
      int distance = _readHybridInteger(reader, lz77dist.config!, token);
      if (distanceMultiplier == 0) {
        distance++;
      } else if (distance < 120) {
        distance = specialDistances[distance * 2] + distanceMultiplier * specialDistances[distance * 2 + 1];
        if (distance < 1) {
          distance = 1;
        }
      } else {
        distance -= 119;
      }
      if (distance > 1 << 20) {
        distance = 1 << 20;
      }
      if (distance > _decodedSymbolCount) {
        distance = _decodedSymbolCount;
      }
      _copyPosition = _decodedSymbolCount - distance;
      return readSymbol(reader, context, distanceMultiplier: distanceMultiplier);
    }

    final int hybridInt = _readHybridInteger(reader, dist.config!, token);
    if (usesLz77) {
      _window![_decodedSymbolCount++ & 0xFFFFF] = hybridInt;
    }
    return hybridInt;
  }

  /// Expands a hybrid-integer [encodedToken] from the bitstream.
  @pragma('vm:prefer-inline')
  int _readHybridInteger(BitReader reader, HybridIntegerConfig config, int encodedToken) {
    int token = encodedToken;
    final int split = 1 << config.splitExponent;
    if (token < split) {
      return token;
    }
    // libjxl (lib/jxl/dec_ans.h, ReadHybridUintConfig) masks this to 0-31
    // via `nbits &= 31u` -- NOT a "reject if too large" check. For n==32
    // specifically this means reading *zero* extra bits (32 & 31 == 0),
    // not 32 -- a real, confirmed divergence from the "if (n>32) throw"
    // shape jxlatte uses (and this code used to mirror), normally
    // unreachable for ordinary 8-16-bit samples, whose residuals never
    // push `n` anywhere near 32, but load-bearing for wide-range content
    // (e.g. float samples reinterpreted as packed 32-bit integers, see
    // ImageBuffer.reconstructFloatSamples) where it silently desyncs the
    // entropy stream instead of throwing.
    final int n = (config.splitExponent - config.lsbInToken - config.msbInToken + ((token - split) >> (config.msbInToken + config.lsbInToken))) & 31;
    final int low = token & ((1 << config.lsbInToken) - 1);
    token >>= config.lsbInToken;
    token &= (1 << config.msbInToken) - 1;
    token |= 1 << config.msbInToken;
    // n is now always 0-31 (masked above), so a plain `token << n` would
    // be safe here too, but wideShl costs nothing extra and keeps this
    // consistent with the rest of this file's shift handling. The
    // hybrid-uint result is a 32-bit *unsigned* quantity by construction
    // (libjxl computes this via `size_t` then an explicit
    // `static_cast<uint32_t>` at the end, lib/jxl/dec_ans.h
    // ReadHybridUintConfig) -- masking once at the end reproduces that,
    // since truncation commutes with `<<`/`|` (unlike `+`/`*`, no carry
    // crosses the truncation boundary).
    return (((wideShl(token, n) | reader.readBits(n)) << config.lsbInToken) | low) & 0xFFFFFFFF;
  }
}
