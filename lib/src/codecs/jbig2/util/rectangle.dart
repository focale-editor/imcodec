// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 rectangle procedure.
class _Jbig2Rectangle {
  /// Stores x.
  final int x;

  /// Stores y.
  final int y;

  /// Stores width.
  final int width;

  /// Stores height.
  final int height;

  /// Creates the rectangle state.
  const _Jbig2Rectangle({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Returns max x.
  int get maxX => x + width;

  /// Returns max y.
  int get maxY => y + height;
}
