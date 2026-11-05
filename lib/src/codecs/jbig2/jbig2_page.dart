part of '../jbig2.dart';

/// Composes page-associated regions in segment order.
final class _Jbig2Page {
  /// Segments belonging to this page, ordered by their sequence number.
  final Map<int, _Jbig2Segment> segments = SplayTreeMap();

  /// One-based page association.
  final int pageNumber;

  /// Document providing shared dictionaries and intermediate regions.
  final _Jbig2Document document;

  /// Creates an initially empty page.
  _Jbig2Page({required this.document, required this.pageNumber});

  /// Resolves a local segment, then a global segment.
  _Jbig2Segment? getSegment(int number) => segments[number] ?? document.getGlobalSegment(number);

  /// Locates the unique page information segment.
  _Jbig2Segment? getPageInformationSegment() {
    _Jbig2Segment? result;
    for (final _Jbig2Segment segment in segments.values) {
      if (segment.segmentType == 48) {
        if (result != null) {
          throw const ImageCodecException('Duplicate JBIG2 page information');
        }
        result = segment;
      }
    }
    return result;
  }

  /// Reads the page dimensions and composition flags.
  _Jbig2PageInformation get information {
    final _Jbig2Segment? header = getPageInformationSegment();
    if (header == null) {
      throw const ImageCodecException('JBIG2 page information is missing');
    }
    return header.getSegmentData()! as _Jbig2PageInformation;
  }

  /// Resolves unknown page height from stripe trailers without decoding pixels.
  int getHeight() {
    final _Jbig2PageInformation info = information;
    if (info.bitmapHeight != -1) {
      return info.bitmapHeight;
    }
    if (!info.isStriped) {
      throw const ImageCodecException('Unknown JBIG2 page height requires stripes');
    }
    int height = 0;
    for (final _Jbig2Segment segment in segments.values) {
      if (segment.segmentType == 50) {
        final int next = (segment.getSegmentData()! as _Jbig2EndOfStripe).getLineNumber() + 1;
        if (next <= height) {
          throw const ImageCodecException('JBIG2 stripe endings must increase');
        }
        height = next;
      }
    }
    if (height == 0) {
      throw const ImageCodecException('JBIG2 striped page has no end-of-stripe segment');
    }
    return height;
  }

  /// Decodes and clips all immediate regions into the page bitmap.
  _Jbig2Bitmap getBitmap() {
    final _Jbig2PageInformation info = information;
    final _Jbig2Bitmap bitmap = _Jbig2Bitmap(width: info.bitmapWidth, height: getHeight());
    if (info.defaultPixelValue != 0) {
      bitmap.bitmap.fillRange(0, bitmap.bitmap.length, 255);
    }
    for (final _Jbig2Segment segment in segments.values) {
      if (![6, 7, 22, 23, 38, 39, 42, 43].contains(segment.segmentType)) {
        continue;
      }
      final _Jbig2Region region = segment.getSegmentData()! as _Jbig2Region;
      final _Jbig2RegionSegmentInformation regionInfo = region.getRegionInfo();
      final bool pageRefinement = region is _Jbig2GenericRefinementRegion && !segment.rtSegments.any((reference) => [4, 20, 36, 40].contains(reference.segmentType));
      if (pageRefinement) {
        region.setPageAsReference(
          _Jbig2Bitmaps.extract(_Jbig2Rectangle(x: regionInfo.xLocation, y: regionInfo.yLocation, width: regionInfo.bitmapWidth, height: regionInfo.bitmapHeight), bitmap),
        );
      }
      final _Jbig2CombinationOperator operator = pageRefinement
          ? _Jbig2CombinationOperator.replace
          : (info.combinationOperatorOverrideAllowed ? regionInfo.combinationOperator : info.combinationOperator);
      _Jbig2Bitmaps.blit(region.getRegionBitmap(), bitmap, regionInfo.xLocation, regionInfo.yLocation, operator);
    }
    return bitmap;
  }

  /// Registers a segment already validated by the document parser.
  void add(_Jbig2Segment segment) => segments[segment.segmentNr] = segment;
}
