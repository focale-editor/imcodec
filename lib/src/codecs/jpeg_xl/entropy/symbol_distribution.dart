import 'package:imcodec/src/codecs/jpeg_xl/entropy/hybrid_uint.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Mutable ANS decoder state, shared across all distributions of one
/// entropy-coded section.
final class AnsState {
  /// Current range-ANS decoder state.
  int _state = 0;

  /// Whether state is present.
  bool hasState = false;

  /// Current range-ANS decoder state.
  int get state => _state;

  /// Returns the current streaming state.
  set state(int value) {
    _state = value;
    hasState = true;
  }

  /// Resets the accumulated state.
  void reset() => hasState = false;
}

/// One symbol distribution (prefix-coded or ANS-coded) within an entropy
/// stream.
abstract base class SymbolDistribution {
  /// Hybrid-integer expansion config, attached after construction.
  HybridIntegerConfig? config;

  /// Dimensions or allocation size of log bucket in the symbol distribution.
  int logBucketSize = 0;

  /// Dimensions or allocation size of alphabet in the symbol distribution.
  int alphabetSize = 0;

  /// Dimensions or allocation size of log alphabet in the symbol distribution.
  int logAlphabetSize = 0;

  /// Reads one entropy-coded symbol.
  int readSymbol(BitReader reader, AnsState state);
}
