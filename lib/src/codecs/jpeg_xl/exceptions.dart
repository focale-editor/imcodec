/// Base class for all errors thrown by the JPEG XL decoder.
sealed class JpegXlException implements Exception {
  /// Human-readable explanation of the codec failure.
  final String message;

  /// Creates a JPEG XL codec exception.
  const JpegXlException({required this.message});

  @override
  String toString() => '$runtimeType: $message';
}

/// The input is not a valid JPEG XL bitstream.
final class JpegXlInvalidBitstreamException extends JpegXlException {
  /// Creates an invalid-bitstream exception.
  const JpegXlInvalidBitstreamException({required super.message});
}

/// The input ended before the decoder could finish reading.
final class JpegXlTruncatedException extends JpegXlException {
  /// Creates a truncated-input exception.
  const JpegXlTruncatedException({required super.message});
}

/// The bitstream is valid but uses a feature this decoder does not support.
///
/// [feature] is a stable identifier (e.g. `'vardct'`, `'animation'`) so
/// callers can decide per-file whether to fall back to another decoder.
final class JpegXlUnsupportedException extends JpegXlException {
  /// Stable identifier for the unsupported bitstream feature.
  final String feature;

  /// Creates an unsupported-feature exception.
  JpegXlUnsupportedException({required this.feature}) : super(message: 'unsupported JPEG XL feature: $feature');
}
