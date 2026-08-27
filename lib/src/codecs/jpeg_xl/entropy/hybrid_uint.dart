import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The (splitExponent, msbInToken, lsbInToken) configuration that expands an
/// entropy token into a full unsigned integer.
final class HybridIntegerConfig {
  /// Exponent separating direct tokens from expanded integers.
  final int splitExponent;

  /// Number of most-significant payload bits stored in each token.
  final int msbInToken;

  /// Number of least-significant payload bits stored in each token.
  final int lsbInToken;

  /// Creates a hybrid integer config.
  const HybridIntegerConfig({
    required this.splitExponent,
    required this.msbInToken,
    required this.lsbInToken,
  });

  /// Reads this structure from the bitstream.
  factory HybridIntegerConfig.read({
    required BitReader reader,
    required int logAlphabetSize,
  }) {
    final int splitExponent = reader.readBits(ceilLog1p(logAlphabetSize));
    if (splitExponent == logAlphabetSize) {
      return HybridIntegerConfig(splitExponent: splitExponent, msbInToken: 0, lsbInToken: 0);
    }
    final int msbInToken = reader.readBits(ceilLog1p(splitExponent));
    if (msbInToken > splitExponent) {
      throw const JpegXlInvalidBitstreamException(message: 'msbInToken too large');
    }
    final int lsbInToken = reader.readBits(ceilLog1p(splitExponent - msbInToken));
    if (msbInToken + lsbInToken > splitExponent) {
      throw const JpegXlInvalidBitstreamException(message: 'msbInToken + lsbInToken too large');
    }
    return HybridIntegerConfig(splitExponent: splitExponent, msbInToken: msbInToken, lsbInToken: lsbInToken);
  }

  @override
  String toString() => '$splitExponent-$msbInToken-$lsbInToken';
}
