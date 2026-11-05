// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../jbig2.dart';

/// Implements the JBIG2 dictionary procedure.
abstract class _Jbig2Dictionary implements _Jbig2SegmentData {
  /// Returns dictionary.
  List<_Jbig2Bitmap> getDictionary();
}
