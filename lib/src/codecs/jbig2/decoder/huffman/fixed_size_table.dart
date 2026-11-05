// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 fixed size table procedure.
class _Jbig2FixedSizeTable extends _Jbig2HuffmanTable {
  /// Creates the fixed size table state.
  _Jbig2FixedSizeTable({
    required List<_Jbig2Code> runCodeTable,
  }) {
    initTree(runCodeTable);
  }
}
