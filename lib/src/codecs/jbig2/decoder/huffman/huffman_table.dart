// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 code procedure.
class _Jbig2Code {
  /// Stores prefix length.
  final int prefixLength;

  /// Stores range length.
  final int rangeLength;

  /// Stores range low.
  final int rangeLow;

  /// Stores is lower range.
  final bool isLowerRange;

  /// Stores code.
  int code = -1;

  /// Creates the code state.
  _Jbig2Code({
    required this.prefixLength,
    required this.rangeLength,
    required this.rangeLow,
    required this.isLowerRange,
  });

  @override
  String toString() => '${code != -1 ? _Jbig2ValueNode.bitPattern(code, prefixLength) : "?"}/$prefixLength/$rangeLength/$rangeLow';
}

/// Implements the JBIG2 huffman table procedure.
abstract class _Jbig2HuffmanTable {
  /// Stores root node.
  final _Jbig2InternalNode _rootNode = _Jbig2InternalNode();

  /// Initializes tree.
  void initTree(List<_Jbig2Code> codeTable) {
    preprocessCodes(codeTable);

    codeTable.forEach(_rootNode.append);
  }

  /// Decodes the next value using the current context.
  int decode(_Jbig2BitReader iis) => _rootNode.decode(iis);

  @override
  String toString() => '$_rootNode\n';

  /// Computes preprocess codes.
  void preprocessCodes(List<_Jbig2Code> codeTable) {
    /* Annex B.3 1) - build the histogram */
    int maxPrefixLength = 0;

    for (final c in codeTable) {
      maxPrefixLength = math.max(maxPrefixLength, c.prefixLength);
    }

    final List<int> lenCount = List<int>.filled(maxPrefixLength + 1, 0);
    for (final c in codeTable) {
      lenCount[c.prefixLength]++;
    }

    int curCode;
    final List<int> firstCode = List<int>.filled(lenCount.length + 1, 0);
    lenCount[0] = 0;

    /* Annex B.3 3) */
    for (int curLen = 1; curLen < lenCount.length; curLen++) {
      firstCode[curLen] = (firstCode[curLen - 1] + (lenCount[curLen - 1]) << 1);
      curCode = firstCode[curLen];
      for (final code in codeTable) {
        if (code.prefixLength == curLen) {
          code.code = curCode;
          curCode++;
        }
      }
    }
  }
}
