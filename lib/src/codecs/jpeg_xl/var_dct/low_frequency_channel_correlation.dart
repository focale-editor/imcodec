import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Chroma-from-luma correlation parameters.
final class LowFrequencyChannelCorrelation {
  /// Scale used to convert encoded correlation values.
  final int colorFactor;

  /// Frame-wide correlation applied to the opsin X channel.
  final double baseCorrelationX;

  /// Frame-wide correlation applied to the opsin B channel.
  final double baseCorrelationB;

  /// Scale of low-frequency X-channel correlation adjustments.
  final int lowFrequencyXFactor;

  /// Scale of low-frequency B-channel correlation adjustments.
  final int lowFrequencyBFactor;

  /// Creates a low-frequency channel correlation.
  const LowFrequencyChannelCorrelation() : colorFactor = 84, baseCorrelationX = 0.0, baseCorrelationB = 1.0, lowFrequencyXFactor = 128, lowFrequencyBFactor = 128;

  /// Reads chroma-from-luma correlation parameters from [reader].
  factory LowFrequencyChannelCorrelation.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return const LowFrequencyChannelCorrelation();
    }
    final int colorFactor = reader.readU32(84, 0, 256, 0, 2, 8, 258, 16);
    final double baseCorrelationX = reader.readF16();
    final double baseCorrelationB = reader.readF16();
    final int lowFrequencyXFactor = reader.readBits(8);
    final int lowFrequencyBFactor = reader.readBits(8);
    return LowFrequencyChannelCorrelation._(
      colorFactor: colorFactor,
      baseCorrelationX: baseCorrelationX,
      baseCorrelationB: baseCorrelationB,
      lowFrequencyXFactor: lowFrequencyXFactor,
      lowFrequencyBFactor: lowFrequencyBFactor,
    );
  }

  /// Creates decoded chroma-from-luma correlation parameters.
  const LowFrequencyChannelCorrelation._({
    required this.colorFactor,
    required this.baseCorrelationX,
    required this.baseCorrelationB,
    required this.lowFrequencyXFactor,
    required this.lowFrequencyBFactor,
  });
}
