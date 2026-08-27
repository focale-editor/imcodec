part of '../jpeg.dart';

/// Stores the color-transform fields of an Adobe JPEG application marker.
final class _JpegAdobeMarker {
  /// Marker format version.
  final int version;

  /// First application-defined flag field.
  final int flags0;

  /// Second application-defined flag field.
  final int flags1;

  /// Color-transform identifier, where two denotes YCCK.
  final int transformCode;

  /// Creates a parsed Adobe marker.
  const _JpegAdobeMarker({
    required this.version,
    required this.flags0,
    required this.flags1,
    required this.transformCode,
  });
}
