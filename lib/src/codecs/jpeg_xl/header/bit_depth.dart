import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The `BitDepth` header bundle.
final class BitDepthHeader {
  /// Whether samples use floating-point representation.
  final bool usesFloatSamples;

  /// Number of encoded bits used for each sample.
  final int bitsPerSample;

  /// Number of exponent bits used by floating-point samples.
  final int exponentBits;

  /// Creates a bit depth header.
  const BitDepthHeader() : usesFloatSamples = false, bitsPerSample = 8, exponentBits = 0;

  /// Reads this structure from the bitstream.
  factory BitDepthHeader.read({
    required BitReader reader,
  }) {
    final bool usesFloatSamples = reader.readBool();
    if (usesFloatSamples) {
      final int bits = reader.readU32(32, 0, 16, 0, 24, 0, 1, 6);
      final int exponentBits = 1 + reader.readBits(4);
      return BitDepthHeader._(usesFloatSamples: true, bitsPerSample: bits, exponentBits: exponentBits);
    }
    final int bits = reader.readU32(8, 0, 10, 0, 12, 0, 1, 6);
    return BitDepthHeader._(usesFloatSamples: false, bitsPerSample: bits, exponentBits: 0);
  }

  /// Creates a bit depth header.
  const BitDepthHeader._({
    required this.usesFloatSamples,
    required this.bitsPerSample,
    required this.exponentBits,
  });

  /// Maximum sample value represented by this bit depth.
  int get maxValue => (1 << bitsPerSample) - 1;

  @override
  String toString() => usesFloatSamples ? '$bitsPerSample-bit float (exponent $exponentBits)' : '$bitsPerSample-bit';
}
