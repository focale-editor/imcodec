import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The `BitDepth` header bundle.
final class BitDepthHeader {
  /// Stores the uses float samples value used while processing JPEG XL data.
  ///
  final bool usesFloatSamples;

  /// Stores the bits per sample value used while processing JPEG XL data.
  ///
  final int bitsPerSample;

  /// Stores the exp bits value used while processing JPEG XL data.
  ///
  final int expBits;

  /// Creates Bit depth header data for JPEG XL processing.
  ///
  const BitDepthHeader() : usesFloatSamples = false, bitsPerSample = 8, expBits = 0;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory BitDepthHeader.read({
    required BitReader reader,
  }) {
    final bool usesFloatSamples = reader.readBool();
    if (usesFloatSamples) {
      final int bits = reader.readU32(32, 0, 16, 0, 24, 0, 1, 6);
      final int expBits = 1 + reader.readBits(4);
      return BitDepthHeader._(usesFloatSamples: true, bitsPerSample: bits, expBits: expBits);
    }
    final int bits = reader.readU32(8, 0, 10, 0, 12, 0, 1, 6);
    return BitDepthHeader._(usesFloatSamples: false, bitsPerSample: bits, expBits: 0);
  }

  /// Creates Bit depth header state for JPEG XL processing.
  ///
  const BitDepthHeader._({
    required this.usesFloatSamples,
    required this.bitsPerSample,
    required this.expBits,
  });

  /// Processes max value information in a JPEG XL codestream.
  ///
  int get maxValue => (1 << bitsPerSample) - 1;

  @override
  String toString() => usesFloatSamples ? '$bitsPerSample-bit float (exp $expBits)' : '$bitsPerSample-bit';
}
