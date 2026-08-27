import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Describes the progressive coefficient passes declared by a frame header.
final class ProgressivePasses {
  /// Number of coefficient passes.
  final int passCount;

  /// Number of downsampling stages.
  final int downsamplingCount;

  /// Bit shift applied to coefficients in each pass.
  final List<int> coefficientShifts;

  /// Downsampling factor available after each stage.
  final List<int> downsamplingFactors;

  /// Final pass contributing to each downsampling stage.
  final List<int> lastPassByDownsampling;

  /// Returns the specification defaults.
  ProgressivePasses.defaults() : passCount = 1, downsamplingCount = 0, coefficientShifts = const [0], downsamplingFactors = const [1], lastPassByDownsampling = const [0];

  /// Reads progressive-pass metadata from [reader].
  factory ProgressivePasses.read({
    required BitReader reader,
  }) {
    final int passCount = reader.readU32(1, 0, 2, 0, 3, 0, 4, 3);
    final int downsamplingCount = passCount != 1 ? reader.readU32(0, 0, 1, 0, 2, 0, 3, 1) : 0;
    if (downsamplingCount >= passCount) {
      throw const JpegXlInvalidBitstreamException(message: 'num_ds < num_passes violated');
    }
    final List<int> coefficientShifts = List<int>.filled(passCount, 0);
    for (var i = 0; i < passCount - 1; i++) {
      coefficientShifts[i] = reader.readBits(2);
    }
    final List<int> downsamplingFactors = List<int>.filled(downsamplingCount + 1, 1);
    for (var i = 0; i < downsamplingCount; i++) {
      downsamplingFactors[i] = 1 << reader.readBits(2);
    }
    final List<int> lastPassByDownsampling = List<int>.filled(downsamplingCount + 1, passCount - 1);
    for (var i = 0; i < downsamplingCount; i++) {
      lastPassByDownsampling[i] = reader.readU32(0, 0, 1, 0, 2, 0, 0, 3);
    }
    return ProgressivePasses._(
      passCount: passCount,
      downsamplingCount: downsamplingCount,
      coefficientShifts: coefficientShifts,
      downsamplingFactors: downsamplingFactors,
      lastPassByDownsampling: lastPassByDownsampling,
    );
  }

  /// Creates decoded progressive-pass metadata.
  ProgressivePasses._({
    required this.passCount,
    required this.downsamplingCount,
    required this.coefficientShifts,
    required this.downsamplingFactors,
    required this.lastPassByDownsampling,
  });
}
