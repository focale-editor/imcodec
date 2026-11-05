// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../jbig2.dart';

/// Implements the JBIG2 segment data procedure.
abstract class _Jbig2SegmentData {
  /// Initializes the arithmetic interval from the first input bytes.
  void init(_Jbig2Segment? header, _Jbig2BitReader sis);
}
