import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Chroma-from-luma correlation parameters.
final class LfChannelCorrelation {
  /// Stores the color factor value used while processing JPEG XL data.
  ///
  final int colorFactor;

  /// Stores the base correlation x value used while processing JPEG XL data.
  ///
  final double baseCorrelationX;

  /// Stores the base correlation b value used while processing JPEG XL data.
  ///
  final double baseCorrelationB;

  /// Stores the x factor lF value used while processing JPEG XL data.
  ///
  final int xFactorLF;

  /// Stores the b factor lF value used while processing JPEG XL data.
  ///
  final int bFactorLF;

  /// Creates Lf channel correlation data for JPEG XL processing.
  ///
  const LfChannelCorrelation() : colorFactor = 84, baseCorrelationX = 0.0, baseCorrelationB = 1.0, xFactorLF = 128, bFactorLF = 128;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory LfChannelCorrelation.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return const LfChannelCorrelation();
    }
    final int colorFactor = reader.readU32(84, 0, 256, 0, 2, 8, 258, 16);
    final double baseCorrelationX = reader.readF16();
    final double baseCorrelationB = reader.readF16();
    final int xFactorLF = reader.readBits(8);
    final int bFactorLF = reader.readBits(8);
    return LfChannelCorrelation._(colorFactor: colorFactor, baseCorrelationX: baseCorrelationX, baseCorrelationB: baseCorrelationB, xFactorLF: xFactorLF, bFactorLF: bFactorLF);
  }

  /// Creates Lf channel correlation state for JPEG XL processing.
  ///
  const LfChannelCorrelation._({
    required this.colorFactor,
    required this.baseCorrelationX,
    required this.baseCorrelationB,
    required this.xFactorLF,
    required this.bFactorLF,
  });
}
