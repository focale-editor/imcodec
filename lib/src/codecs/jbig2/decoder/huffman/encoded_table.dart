// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 encoded table procedure.
class _Jbig2EncodedTable extends _Jbig2HuffmanTable {
  /// Stores table.
  final _Jbig2Table table;

  /// Creates the encoded table state.
  _Jbig2EncodedTable({
    required this.table,
  }) {
    _parseTable();
  }

  /// Parses table.
  void _parseTable() {
    final _Jbig2BitReader sis = table.subInputStream;
    final List<_Jbig2Code> codeTable = <_Jbig2Code>[];

    int prefLen;
    int rangeLen;
    int rangeLow;
    int curRangeLow = table.htLow;

    /* Annex B.2 5) - decode table lines */
    while (curRangeLow < table.htHigh) {
      prefLen = sis.readBits(table.htPS);
      rangeLen = sis.readBits(table.htRS);
      if (rangeLen > 32 || prefLen > 32) {
        throw const ImageCodecException('Invalid JBIG2 Huffman table length');
      }
      rangeLow = curRangeLow;

      codeTable.add(_Jbig2Code(prefixLength: prefLen, rangeLength: rangeLen, rangeLow: rangeLow, isLowerRange: false));

      curRangeLow += math.pow(2, rangeLen).toInt();
    }

    /* Annex B.2 6) */
    prefLen = sis.readBits(table.htPS);

    /*
     * Annex B.2 7) - lower range table line
     */
    rangeLen = 32;
    rangeLow = table.htLow - 1;
    codeTable.add(_Jbig2Code(prefixLength: prefLen, rangeLength: rangeLen, rangeLow: rangeLow, isLowerRange: true));

    /* Annex B.2 8) */
    prefLen = sis.readBits(table.htPS);

    /* Annex B.2 9) - upper range table line */
    rangeLen = 32;
    rangeLow = table.htHigh;
    codeTable.add(_Jbig2Code(prefixLength: prefLen, rangeLength: rangeLen, rangeLow: rangeLow, isLowerRange: false));

    /* Annex B.2 10) - out-of-band table line */
    if (table.htOOB == 1) {
      prefLen = sis.readBits(table.htPS);
      codeTable.add(_Jbig2Code(prefixLength: prefLen, rangeLength: -1, rangeLow: -1, isLowerRange: false));
    }

    initTree(codeTable);
  }
}
