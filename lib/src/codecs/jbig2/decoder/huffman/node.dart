// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 node procedure.
abstract class _Jbig2Node {
  /// Decodes the next value using the current context.
  int decode(_Jbig2BitReader iis);
}
