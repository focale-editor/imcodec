import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The `AnimationHeader` bundle. Parsed for bitstream correctness; animated
/// frames themselves are not decoded in v1.
final class AnimationHeader {
  /// Stores the tps numerator value used while processing JPEG XL data.
  ///
  final int tpsNumerator;

  /// Stores the tps denominator value used while processing JPEG XL data.
  ///
  final int tpsDenominator;

  /// Stores the num loops value used while processing JPEG XL data.
  ///
  final int numLoops;

  /// Stores the have timecodes value used while processing JPEG XL data.
  ///
  final bool haveTimecodes;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory AnimationHeader.read({
    required BitReader reader,
  }) {
    final int tpsNumerator = reader.readU32(100, 0, 1000, 0, 1, 10, 1, 30);
    final int tpsDenominator = reader.readU32(1, 0, 1001, 0, 1, 8, 1, 10);
    final int numLoops = reader.readU32(0, 0, 0, 3, 0, 16, 0, 32);
    final bool haveTimecodes = reader.readBool();
    return AnimationHeader._(tpsNumerator: tpsNumerator, tpsDenominator: tpsDenominator, numLoops: numLoops, haveTimecodes: haveTimecodes);
  }

  /// Creates Animation header state for JPEG XL processing.
  ///
  const AnimationHeader._({
    required this.tpsNumerator,
    required this.tpsDenominator,
    required this.numLoops,
    required this.haveTimecodes,
  });
}
