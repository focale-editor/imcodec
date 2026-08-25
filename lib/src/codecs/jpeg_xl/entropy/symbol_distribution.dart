import 'package:imcodec/src/codecs/jpeg_xl/entropy/hybrid_uint.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Mutable ANS decoder state, shared across all distributions of one
/// entropy-coded section.
final class AnsState {
  /// Stores the state state used internally by the JPEG XL codec.
  ///
  int _state = 0;

  /// Stores the has state value used while processing JPEG XL data.
  ///
  bool hasState = false;

  /// Stores the state value used while processing JPEG XL data.
  ///
  int get state => _state;

  /// Processes state information in a JPEG XL codestream.
  ///
  set state(int value) {
    _state = value;
    hasState = true;
  }

  /// Processes reset information in a JPEG XL codestream.
  ///
  void reset() => hasState = false;
}

/// One symbol distribution (prefix-coded or ANS-coded) within an entropy
/// stream.
abstract base class SymbolDistribution {
  /// Hybrid-integer expansion config, attached after construction.
  HybridIntegerConfig? config;

  /// Stores the log bucket size value used while processing JPEG XL data.
  ///
  int logBucketSize = 0;

  /// Stores the alphabet size value used while processing JPEG XL data.
  ///
  int alphabetSize = 0;

  /// Stores the log alphabet size value used while processing JPEG XL data.
  ///
  int logAlphabetSize = 0;

  /// Processes read symbol information in a JPEG XL codestream.
  ///
  int readSymbol(BitReader reader, AnsState state);
}
