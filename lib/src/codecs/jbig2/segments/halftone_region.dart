// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 halftone region procedure.
class _Jbig2HalftoneRegion implements _Jbig2Region {
  /// Stores sub input stream.
  _Jbig2BitReader? subInputStream;

  /// Stores segment header.
  _Jbig2Segment? segmentHeader;

  /// Stores data header offset.
  final int _dataHeaderOffset = 0;

  /// Stores data header length.
  int _dataHeaderLength = 0;

  /// Stores data offset.
  int _dataOffset = 0;

  /// Stores data length.
  int _dataLength = 0;

  /// Stores region info.
  late _Jbig2RegionSegmentInformation _regionInfo;

  // Halftone segment information field
  /// Stores h default pixel.
  int _hDefaultPixel = 0;

  /// Stores h combination operator.
  _Jbig2CombinationOperator _hCombinationOperator = _Jbig2CombinationOperator.or;

  /// Stores h skip enabled.
  bool _hSkipEnabled = false;

  /// Stores h template.
  int _hTemplate = 0;

  /// Stores is mmrencoded.
  bool _isMMREncoded = false;

  // Halftone grid position and size
  /// Stores h grid width.
  int _hGridWidth = 0;

  /// Stores h grid height.
  int _hGridHeight = 0;

  /// Stores h grid x.
  int _hGridX = 0;

  /// Stores h grid y.
  int _hGridY = 0;

  // Halftone grid vector
  /// Stores h region x.
  int _hRegionX = 0;

  /// Stores h region y.
  int _hRegionY = 0;

  // Decoded data
  /// Stores halftone region bitmap.
  _Jbig2Bitmap? _halftoneRegionBitmap;

  // Previously decoded data from other regions or dictionaries
  /// Stores patterns.
  List<_Jbig2Bitmap>? _patterns;

  /// Creates the halftone region state.
  _Jbig2HalftoneRegion() : segmentHeader = null, subInputStream = null {
    if (subInputStream != null) {
      _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    }
  }

  /// Parses header.
  void _parseHeader() {
    _regionInfo.parseHeader();

    _hDefaultPixel = subInputStream!.readBit();
    _hCombinationOperator = _Jbig2CombinationOperator.translateOperatorCodeToEnum(subInputStream!.readBits(3) & 0xf);

    if (subInputStream!.readBit() == 1) {
      _hSkipEnabled = true;
    }

    _hTemplate = subInputStream!.readBits(2) & 0xf;

    if (subInputStream!.readBit() == 1) {
      _isMMREncoded = true;
    }

    _hGridWidth = subInputStream!.readBits(32) & 0xffffffff;
    _hGridHeight = subInputStream!.readBits(32) & 0xffffffff;
    _Jbig2Budget.current.checkDimensions(_hGridWidth, _hGridHeight);
    _Jbig2Budget.reserve(_hGridWidth * _hGridHeight, 8);

    // 7.4.5.1.2: HGX and HGY are signed 32 bit fixed point values with eight
    // fractional bits.
    _hGridX = subInputStream!.readBits(32).toSigned(32);
    _hGridY = subInputStream!.readBits(32).toSigned(32);

    // 7.4.5.1.3: HRX and HRY are unsigned 16 bit fixed point values.
    _hRegionX = subInputStream!.readBits(16) & 0xffff;
    _hRegionY = subInputStream!.readBits(16) & 0xffff;

    _computeSegmentDataStructure();
    _checkInput();
  }

  /// Computes segment data structure.
  void _computeSegmentDataStructure() {
    _dataOffset = subInputStream!.getStreamPosition();
    _dataHeaderLength = _dataOffset - _dataHeaderOffset;
    _dataLength = subInputStream!.length - _dataHeaderLength;
  }

  /// Validates input.
  void _checkInput() {
    if (_isMMREncoded) {
      if (_hTemplate != 0) {
        _Jbig2Log.info('hTemplate = $_hTemplate (should contain the value 0)');
      }
      if (_hSkipEnabled) {
        _Jbig2Log.info('hSkipEnabled 0 $_hSkipEnabled (should contain the value false)');
      }
    }
  }

  @override
  _Jbig2Bitmap getRegionBitmap() {
    if (_halftoneRegionBitmap == null) {
      _halftoneRegionBitmap = _Jbig2Bitmap(width: _regionInfo.bitmapWidth, height: _regionInfo.bitmapHeight);

      _patterns ??= _getPatterns();

      if (_hDefaultPixel == 1) {
        // Fill with 0xff
        for (int i = 0; i < _halftoneRegionBitmap!.getByteArray().length; i++) {
          _halftoneRegionBitmap!.getByteArray()[i] = 0xff;
        }
      }

      /* 6.6.5 2) */
      final _Jbig2Bitmap? skip = _hSkipEnabled ? _computeSkipBitmap() : null;

      /* 6.6.5 3) */
      final int bitsPerValue = (math.log(_patterns!.length) / math.log(2)).ceil();

      /* 6.6.5 4) and 5) */
      final List<List<int>> grayScaleValues = _grayScaleDecoding(bitsPerValue, skip);
      _renderPattern(grayScaleValues);
    }
    return _halftoneRegionBitmap!;
  }

  /// Computes render pattern.
  void _renderPattern(List<List<int>> grayScaleValues) {
    int x = 0;
    int y = 0;
    for (int m = 0; m < _hGridHeight; m++) {
      for (int n = 0; n < _hGridWidth; n++) {
        x = _computeX(m, n);
        y = _computeY(m, n);
        final _Jbig2Bitmap patternBitmap = _patterns![grayScaleValues[m][n]];
        // 6.6.5.2 draws the pattern at (x, y). _computeX and _computeY already
        // fold HGX and HGY in and apply the >>A 8, so adding them a second
        // time here would both double the origin and mix the fixed point value
        // into a pixel coordinate. A stream with HGX = HGY = 0 hides the
        // mistake, which is why only a shifted grid exposes it.
        _Jbig2Bitmaps.blit(patternBitmap, _halftoneRegionBitmap!, x, y, _hCombinationOperator);
      }
    }
  }

  /// Returns patterns.
  List<_Jbig2Bitmap> _getPatterns() {
    final List<_Jbig2Bitmap> patterns = [];
    if (segmentHeader != null) {
      for (final _Jbig2Segment s in segmentHeader!.rtSegments) {
        final _Jbig2PatternDictionary patternDictionary = s.getSegmentData() as _Jbig2PatternDictionary;
        patterns.addAll(patternDictionary.getDictionary());
      }
    }
    return patterns;
  }

  /// 6.6.5.1: HSKIP marks the halftone grid cells whose pattern would fall
  /// entirely outside the region. Those cells are not coded at all, so the
  /// generic decoding procedure must skip them rather than read a decision for
  /// them; getting this wrong desynchronises the arithmetic decoder for the
  /// whole rest of the grey-scale image.
  _Jbig2Bitmap _computeSkipBitmap() {
    final int patternWidth = _patterns!.first.width;
    final int patternHeight = _patterns!.first.height;
    final _Jbig2Bitmap skip = _Jbig2Bitmap(width: _hGridWidth, height: _hGridHeight);

    for (int mg = 0; mg < _hGridHeight; mg++) {
      for (int ng = 0; ng < _hGridWidth; ng++) {
        final int x = _computeX(mg, ng);
        final int y = _computeY(mg, ng);
        if (x + patternWidth <= 0 || x >= _regionInfo.bitmapWidth || y + patternHeight <= 0 || y >= _regionInfo.bitmapHeight) {
          skip.setPixel(ng, mg, 1);
        }
      }
    }
    return skip;
  }

  /// Computes gray scale decoding.
  List<List<int>> _grayScaleDecoding(int bitsPerValue, _Jbig2Bitmap? skip) {
    List<int>? gbAtX;
    List<int>? gbAtY;

    if (!_isMMREncoded) {
      gbAtX = List.filled(4, 0);
      gbAtY = List.filled(4, 0);
      if (_hTemplate <= 1) {
        gbAtX[0] = 3;
      } else if (_hTemplate >= 2) {
        gbAtX[0] = 2;
      }
      gbAtY[0] = -1;
      gbAtX[1] = -3;
      gbAtY[1] = -1;
      gbAtX[2] = 2;
      gbAtY[2] = -2;
      gbAtX[3] = -2;
      gbAtY[3] = -2;
    }

    final List<_Jbig2Bitmap?> grayScalePlanes = List.filled(bitsPerValue, null);

    final _Jbig2GenericRegion genericRegion = _Jbig2GenericRegion(subInputStream: subInputStream);
    genericRegion.setParametersForPattern(
      _isMMREncoded,
      _dataOffset,
      _dataLength,
      _hGridHeight,
      _hGridWidth,
      _hTemplate,
      false,
      skip,

      gbAtX,
      gbAtY,
    );

    int j = bitsPerValue - 1;
    grayScalePlanes[j] = genericRegion.getRegionBitmap();

    while (j > 0) {
      j--;
      genericRegion.resetBitmap();
      grayScalePlanes[j] = genericRegion.getRegionBitmap();
      _combineGrayScalePlanes(grayScalePlanes, j);
    }

    return _computeGrayScaleValues(grayScalePlanes, bitsPerValue);
  }

  /// Computes combine gray scale planes.
  void _combineGrayScalePlanes(List<_Jbig2Bitmap?> grayScalePlanes, int j) {
    int byteIndex = 0;
    for (int y = 0; y < grayScalePlanes[j]!.height; y++) {
      for (int x = 0; x < grayScalePlanes[j]!.width; x += 8) {
        final int newValue = grayScalePlanes[j + 1]!.getByte(byteIndex);
        final int oldValue = grayScalePlanes[j]!.getByte(byteIndex);
        grayScalePlanes[j]!.setByte(byteIndex++, _Jbig2Bitmaps.combineBytes(oldValue, newValue, _Jbig2CombinationOperator.xor));
      }
    }
  }

  /// Computes gray scale values.
  List<List<int>> _computeGrayScaleValues(List<_Jbig2Bitmap?> grayScalePlanes, int bitsPerValue) {
    final List<List<int>> grayScaleValues = List.generate(_hGridHeight, (_) => List.filled(_hGridWidth, 0));

    for (int y = 0; y < _hGridHeight; y++) {
      for (int x = 0; x < _hGridWidth; x += 8) {
        final int minorWidth = _hGridWidth - x > 8 ? 8 : _hGridWidth - x;
        final int byteIndex = grayScalePlanes[0]!.getByteIndex(x, y);

        for (int minorX = 0; minorX < minorWidth; minorX++) {
          final int i = minorX + x;
          grayScaleValues[y][i] = 0;

          for (int j = 0; j < bitsPerValue; j++) {
            grayScaleValues[y][i] += ((grayScalePlanes[j]!.getByte(byteIndex) >> (7 - i & 7)) & 1) * (1 << j);
          }
        }
      }
    }
    return grayScaleValues;
  }

  /// Computes x.
  int _computeX(int m, int n) => _shiftAndFill((_hGridX + m * _hRegionY + n * _hRegionX));

  /// Computes y.
  int _computeY(int m, int n) => _shiftAndFill((_hGridY + m * _hRegionX - n * _hRegionY));

  /// The `>>A 8` of 6.6.5.1 and 6.6.5.2: an arithmetic shift that keeps the
  /// sign, which is what Dart's `>>` already does on an `int`.
  int _shiftAndFill(int value) => value >> 8;

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    segmentHeader = header;
    subInputStream = sis;
    _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    _parseHeader();
  }

  @override
  _Jbig2RegionSegmentInformation getRegionInfo() => _regionInfo;

  /// Returns is mmrencoded.
  bool get isMMREncoded => _isMMREncoded;

  /// Returns h template.
  int get hTemplate => _hTemplate;

  /// Returns is hskip enabled.
  bool get isHSkipEnabled => _hSkipEnabled;

  /// Returns combination operator.
  _Jbig2CombinationOperator get combinationOperator => _hCombinationOperator;

  /// Returns h default pixel.
  int get hDefaultPixel => _hDefaultPixel;

  /// Returns h grid width.
  int get hGridWidth => _hGridWidth;

  /// Returns h grid height.
  int get hGridHeight => _hGridHeight;

  /// Returns h grid x.
  int get hGridX => _hGridX;

  /// Returns h grid y.
  int get hGridY => _hGridY;

  /// Returns h region x.
  int get hRegionX => _hRegionX;

  /// Returns h region y.
  int get hRegionY => _hRegionY;
}
