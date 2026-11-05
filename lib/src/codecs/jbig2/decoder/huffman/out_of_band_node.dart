// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 out of band node procedure.
class _Jbig2OutOfBandNode extends _Jbig2Node {
  /// Creates the out of band node state.
  _Jbig2OutOfBandNode({
    required _Jbig2Code c,
  });

  @override
  int decode(_Jbig2BitReader iis) => 0x1fffffffffffff;
}
