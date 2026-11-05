// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 page information procedure.
class _Jbig2PageInformation implements _Jbig2SegmentData {
  /// Stores sub input stream.
  late _Jbig2BitReader subInputStream;

  /// Page bitmap width, four byte, 7.4.8.1
  int bitmapWidth = 0;

  /// Page bitmap height, four byte, 7.4.8.2
  int bitmapHeight = 0;

  /// Page X resolution, four byte, 7.4.8.3
  int resolutionX = 0;

  /// Page Y resolution, four byte, 7.4.8.4
  int resolutionY = 0;

  /// Page segment flags, one byte, 7.4.8.5
  bool combinationOperatorOverrideAllowed = false;

  /// Stores combination operator.
  _Jbig2CombinationOperator combinationOperator = _Jbig2CombinationOperator.or; // Default?
  /// Stores requires auxiliary buffer.
  bool requiresAuxiliaryBuffer = false;

  /// Stores default pixel value.
  int defaultPixelValue = 0;

  /// Stores might contain refinements.
  bool mightContainRefinements = false;

  /// Stores is lossless.
  bool isLossless = false;

  /// Page striping information, two byte, 7.4.8.6
  bool isStriped = false;

  /// Stores max stripe size.
  int maxStripeSize = 0;

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    subInputStream = sis;
    parseHeader();
  }

  /// Parses header.
  void parseHeader() {
    readWidthAndHeight();
    readResolution();

    /* Bit 7 */
    subInputStream.readBit(); // dirty read

    /* Bit 6 */
    readCombinationOperatorOverrideAllowed();

    /* Bit 5 */
    readRequiresAuxiliaryBuffer();

    /* Bit 3-4 */
    readCombinationOperator();

    /* Bit 2 */
    readDefaultPixelvalue();

    /* Bit 1 */
    readContainsRefinement();

    /* Bit 0 */
    readIsLossless();

    /* Bit 15 */
    readIsStriped();

    /* Bit 0-14 */
    readMaxStripeSize();

    checkInput();
  }

  /// Reads resolution.
  void readResolution() {
    resolutionX = subInputStream.readBits(32) & 0xffffffff;
    resolutionY = subInputStream.readBits(32) & 0xffffffff;
  }

  /// Validates input.
  void checkInput() {
    if (bitmapWidth < 1 || bitmapHeight == 0 || bitmapHeight < -1 || (bitmapHeight == -1 && !isStriped)) {
      throw const ImageCodecException('Invalid JBIG2 page dimensions or stripe flags');
    }
  }

  /// Reads combination operator override allowed.
  void readCombinationOperatorOverrideAllowed() {
    /* Bit 6 */
    if (subInputStream.readBit() == 1) {
      combinationOperatorOverrideAllowed = true;
    }
  }

  /// Reads requires auxiliary buffer.
  void readRequiresAuxiliaryBuffer() {
    /* Bit 5 */
    if (subInputStream.readBit() == 1) {
      requiresAuxiliaryBuffer = true;
    }
  }

  /// Reads combination operator.
  void readCombinationOperator() {
    /* Bit 3-4 */
    combinationOperator = _Jbig2CombinationOperator.translateOperatorCodeToEnum(subInputStream.readBits(2) & 0xf);
  }

  /// Reads default pixelvalue.
  void readDefaultPixelvalue() {
    /* Bit 2 */
    defaultPixelValue = subInputStream.readBit();
  }

  /// Reads contains refinement.
  void readContainsRefinement() {
    /* Bit 1 */
    if (subInputStream.readBit() == 1) {
      mightContainRefinements = true;
    }
  }

  /// Reads is lossless.
  void readIsLossless() {
    /* Bit 0 */
    if (subInputStream.readBit() == 1) {
      isLossless = true;
    }
  }

  /// Reads is striped.
  void readIsStriped() {
    /* Bit 15 */
    if (subInputStream.readBit() == 1) {
      isStriped = true;
    }
  }

  /// Reads max stripe size.
  void readMaxStripeSize() {
    /* Bit 0-14 */
    maxStripeSize = subInputStream.readBits(15) & 0xffff;
  }

  /// Reads width and height.
  void readWidthAndHeight() {
    bitmapWidth = subInputStream.readBits(32).toSigned(32);
    bitmapHeight = subInputStream.readBits(32).toSigned(32);
  }

  /// Returns width.
  int getWidth() => bitmapWidth;

  /// Returns height.
  int getHeight() => bitmapHeight;

  /// Returns resolution x.
  int getResolutionX() => resolutionX;

  /// Returns resolution y.
  int getResolutionY() => resolutionY;

  /// Returns default pixel value.
  int getDefaultPixelValue() => defaultPixelValue;

  /// Computes is combination operator override allowed.
  bool isCombinationOperatorOverrideAllowed() => combinationOperatorOverrideAllowed;

  /// Returns combination operator.
  _Jbig2CombinationOperator getCombinationOperator() => combinationOperator;

  /// Returns is striped.
  bool getIsStriped() => isStriped;

  /// Returns max stripe size.
  int getMaxStripeSize() => maxStripeSize;

  /// Computes is auxiliary buffer required.
  bool isAuxiliaryBufferRequired() => requiresAuxiliaryBuffer;

  /// Returns might contain refinements.
  bool getMightContainRefinements() => mightContainRefinements;

  /// Returns is lossless.
  bool getIsLossless() => isLossless;
}
