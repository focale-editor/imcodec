part of '../jpeg.dart';

/// Stores spatial rows and scaling factors for one decoded JPEG component.
final class _JpegComponentData {
  /// Horizontal sampling factor.
  final int horizontalSamples;

  /// Maximum horizontal sampling factor in the frame.
  final int maximumHorizontalSamples;

  /// Vertical sampling factor.
  final int verticalSamples;

  /// Maximum vertical sampling factor in the frame.
  final int maximumVerticalSamples;

  /// Eight-bit spatial sample rows.
  final List<Uint8List> lines;

  /// Power-of-two horizontal subsampling shift.
  final int horizontalScaleShift;

  /// Power-of-two vertical subsampling shift.
  final int verticalScaleShift;

  /// Creates spatial component data and derives its sampling shifts.
  _JpegComponentData({
    required this.horizontalSamples,
    required this.maximumHorizontalSamples,
    required this.verticalSamples,
    required this.maximumVerticalSamples,
    required this.lines,
  }) : horizontalScaleShift = horizontalSamples == 1 && maximumHorizontalSamples == 2 ? 1 : 0,
       verticalScaleShift = verticalSamples == 1 && maximumVerticalSamples == 2 ? 1 : 0;
}
