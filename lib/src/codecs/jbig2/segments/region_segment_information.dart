// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 region segment information procedure.
class _Jbig2RegionSegmentInformation implements _Jbig2SegmentData {
  /// Stores sub input stream.
  _Jbig2BitReader? subInputStream;

  /// _Jbig2Region segment bitmap width, 7.4.1.1
  int bitmapWidth = 0;

  /// _Jbig2Region segment bitmap height, 7.4.1.2
  int bitmapHeight = 0;

  /// _Jbig2Region segment bitmap X location, 7.4.1.3
  int xLocation = 0;

  /// _Jbig2Region segment bitmap Y location, 7.4.1.4
  int yLocation = 0;

  /// _Jbig2Region segment flags, 7.4.1.5
  _Jbig2CombinationOperator combinationOperator = _Jbig2CombinationOperator.or;

  /// Creates the region segment information state.
  _Jbig2RegionSegmentInformation({
    this.subInputStream,
  });

  /// Parses header.
  void parseHeader() {
    if (subInputStream == null) {
      return;
    }

    bitmapWidth = subInputStream!.readBits(32);
    bitmapHeight = subInputStream!.readBits(32);
    xLocation = _toSigned32(subInputStream!.readBits(32));
    yLocation = _toSigned32(subInputStream!.readBits(32));

    /* Bit 3-7 */
    subInputStream!.readBits(5); // Dirty read... reserved bits are 0

    /* Bit 0-2 */
    readCombinationOperator();
  }

  /// Computes to signed32.
  int _toSigned32(int val) {
    if (val >= 0x80000000) {
      return val - 0x100000000;
    }
    return val;
  }

  /// Reads combination operator.
  void readCombinationOperator() {
    if (subInputStream == null) {
      return;
    }
    combinationOperator = _Jbig2CombinationOperator.translateOperatorCodeToEnum(subInputStream!.readBits(3) & 0xf);
  }

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {}

  /// Updates bitmap width.
  void setBitmapWidth(int bitmapWidth) {
    this.bitmapWidth = bitmapWidth;
  }

  /// Returns bitmap width.
  int getBitmapWidth() => bitmapWidth;

  /// Updates bitmap height.
  void setBitmapHeight(int bitmapHeight) {
    this.bitmapHeight = bitmapHeight;
  }

  /// Returns bitmap height.
  int getBitmapHeight() => bitmapHeight;

  /// Returns xlocation.
  int getXLocation() => xLocation;

  /// Returns ylocation.
  int getYLocation() => yLocation;

  /// Returns combination operator.
  _Jbig2CombinationOperator getCombinationOperator() => combinationOperator;
}
