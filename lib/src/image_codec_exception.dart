/// Reports invalid input or an unsupported codec operation.
final class ImageCodecException implements Exception {
  /// Creates an image codec error with a human-readable [message].
  const ImageCodecException(this.message, {this.cause});

  /// Description of the failed operation.
  final String message;

  /// Original error, when one was available.
  final Object? cause;

  @override
  String toString() => cause == null ? 'ImageCodecException: $message' : 'ImageCodecException: $message ($cause)';
}
