import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// The (splitExponent, msbInToken, lsbInToken) configuration that expands an
/// entropy token into a full unsigned integer.
final class HybridIntegerConfig {
  /// Stores the split exponent value used while processing JPEG XL data.
  ///
  final int splitExponent;

  /// Stores the msb in token value used while processing JPEG XL data.
  ///
  final int msbInToken;

  /// Stores the lsb in token value used while processing JPEG XL data.
  ///
  final int lsbInToken;

  /// Creates Hybrid integer config data for JPEG XL processing.
  ///
  const HybridIntegerConfig({
    required this.splitExponent,
    required this.msbInToken,
    required this.lsbInToken,
  });

  /// Processes read information in a JPEG XL codestream.
  ///
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
