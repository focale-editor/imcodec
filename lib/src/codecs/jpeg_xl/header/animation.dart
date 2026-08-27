import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Describes animation timing and repetition metadata.
final class AnimationHeader {
  /// Numerator of the animation tick rate.
  final int ticksPerSecondNumerator;

  /// Denominator of the animation tick rate.
  final int ticksPerSecondDenominator;

  /// Number of playback loops, where zero means indefinite repetition.
  final int loopCount;

  /// Whether individual frames carry presentation timecodes.
  final bool hasTimecodes;

  /// Reads animation metadata from [reader].
  factory AnimationHeader.read({
    required BitReader reader,
  }) {
    final int ticksPerSecondNumerator = reader.readU32(100, 0, 1000, 0, 1, 10, 1, 30);
    final int ticksPerSecondDenominator = reader.readU32(1, 0, 1001, 0, 1, 8, 1, 10);
    final int loopCount = reader.readU32(0, 0, 0, 3, 0, 16, 0, 32);
    final bool hasTimecodes = reader.readBool();
    return AnimationHeader._(
      ticksPerSecondNumerator: ticksPerSecondNumerator,
      ticksPerSecondDenominator: ticksPerSecondDenominator,
      loopCount: loopCount,
      hasTimecodes: hasTimecodes,
    );
  }

  /// Creates validated animation metadata.
  const AnimationHeader._({
    required this.ticksPerSecondNumerator,
    required this.ticksPerSecondDenominator,
    required this.loopCount,
    required this.hasTimecodes,
  });
}
