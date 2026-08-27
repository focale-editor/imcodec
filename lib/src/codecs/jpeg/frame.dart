part of '../jpeg.dart';

/// Stores one JPEG frame and allocates its coefficient blocks.
final class _JpegFrame {
  /// Whether entropy scans use progressive refinement.
  final bool progressive;

  /// Number of bits stored for each component sample.
  final int precision;

  /// Image height in pixels.
  final int scanLines;

  /// Image width in pixels.
  final int samplesPerLine;

  /// Components indexed by their stream identifiers.
  final Map<int, _JpegComponent> components = {};

  /// Component identifiers in display order.
  final List<int> componentsOrder = [];

  /// Maximum horizontal sampling factor among components.
  int maximumHorizontalSamples = 0;

  /// Maximum vertical sampling factor among components.
  int maximumVerticalSamples = 0;

  /// Number of minimum coded units in each row.
  late int minimumCodedUnitsPerLine;

  /// Number of minimum coded units in each column.
  late int minimumCodedUnitsPerColumn;

  /// Creates a frame from validated header fields.
  _JpegFrame({
    required this.progressive,
    required this.precision,
    required this.scanLines,
    required this.samplesPerLine,
  });

  /// Derives frame geometry and allocates coefficient blocks.
  void prepare() {
    for (final _JpegComponent component in components.values) {
      maximumHorizontalSamples = math.max(maximumHorizontalSamples, component.horizontalSamples);
      maximumVerticalSamples = math.max(maximumVerticalSamples, component.verticalSamples);
    }
    minimumCodedUnitsPerLine = (samplesPerLine / 8 / maximumHorizontalSamples).ceil();
    minimumCodedUnitsPerColumn = (scanLines / 8 / maximumVerticalSamples).ceil();

    for (final _JpegComponent component in components.values) {
      final int blocksPerLine = ((samplesPerLine / 8).ceil() * component.horizontalSamples / maximumHorizontalSamples).ceil();
      final int blocksPerColumn = ((scanLines / 8).ceil() * component.verticalSamples / maximumVerticalSamples).ceil();
      final int paddedColumns = minimumCodedUnitsPerLine * component.horizontalSamples;
      final int paddedRows = minimumCodedUnitsPerColumn * component.verticalSamples;
      component
        ..blocksPerLine = blocksPerLine
        ..blocksPerColumn = blocksPerColumn
        ..blocks = List<List<Int32List>>.generate(
          paddedRows,
          (row) => List<Int32List>.generate(paddedColumns, (column) => Int32List(64), growable: false),
          growable: false,
        );
    }
  }
}
