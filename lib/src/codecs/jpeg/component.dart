part of '../jpeg.dart';

/// Stores sampling, table, and block state for one JPEG component.
final class _JpegComponent {
  /// Horizontal sampling factor.
  final int horizontalSamples;

  /// Vertical sampling factor.
  final int verticalSamples;

  /// Quantization tables shared by the containing image.
  final List<Int16List?> quantizationTables;

  /// Quantization-table identifier selected by this component.
  final int quantizationIndex;

  /// Number of visible blocks in each row.
  late int blocksPerLine;

  /// Number of visible blocks in each column.
  late int blocksPerColumn;

  /// Frequency coefficients including minimum-coded-unit padding.
  late List<List<Int32List>> blocks;

  /// Huffman table used for direct-current coefficients.
  late _JpegHuffmanTable huffmanTableDc;

  /// Huffman table used for alternating-current coefficients.
  late _JpegHuffmanTable huffmanTableAc;

  /// Previous direct-current coefficient for differential coding.
  int prediction = 0;

  /// Creates a component from its frame-header fields.
  _JpegComponent({
    required this.horizontalSamples,
    required this.verticalSamples,
    required this.quantizationTables,
    required this.quantizationIndex,
  });

  /// Quantization table currently referenced by this component.
  Int16List? get quantizationTable => quantizationTables[quantizationIndex];
}
