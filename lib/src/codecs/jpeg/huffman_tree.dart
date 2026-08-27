part of '../jpeg.dart';

/// Base node in a JPEG Huffman decoding tree.
sealed class _JpegHuffmanNode {
  /// Creates a tree node.
  const _JpegHuffmanNode();
}

/// Holds child nodes selected by the next entropy bit.
final class _JpegHuffmanBranch extends _JpegHuffmanNode {
  /// Child nodes indexed by zero or one.
  final List<_JpegHuffmanNode?> children;

  /// Creates a branch over [children].
  const _JpegHuffmanBranch({
    required this.children,
  });
}

/// Holds one decoded Huffman symbol.
final class _JpegHuffmanValue extends _JpegHuffmanNode {
  /// Symbol value.
  final int value;

  /// Creates a leaf containing [value].
  const _JpegHuffmanValue({
    required this.value,
  });
}
