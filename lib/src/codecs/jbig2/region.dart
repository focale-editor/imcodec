// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../jbig2.dart';

/// Implements the JBIG2 region procedure.
abstract class _Jbig2Region implements _Jbig2SegmentData {
  /// Returns region bitmap.
  _Jbig2Bitmap getRegionBitmap();

  /// Returns region info.
  _Jbig2RegionSegmentInformation getRegionInfo();
}
