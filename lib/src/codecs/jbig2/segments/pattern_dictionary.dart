// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 pattern dictionary procedure.
class _Jbig2PatternDictionary implements _Jbig2Dictionary {
  /// Stores sub input stream.
  _Jbig2BitReader? subInputStream;

  // Segment data structure (only necessary if MMR is used)
  /// Stores data header offset.
  final int _dataHeaderOffset = 0;

  /// Stores data header length.
  int _dataHeaderLength = 0;

  /// Stores data offset.
  int _dataOffset = 0;

  /// Stores data length.
  int _dataLength = 0;

  /// Stores gb at x.
  List<int>? _gbAtX;

  /// Stores gb at y.
  List<int>? _gbAtY;

  // Pattern dictionary flags
  /// Stores is mmrencoded.
  bool _isMMREncoded = false;

  /// Stores hd template.
  int _hdTemplate = 0;

  // Width of the patterns in the pattern dictionary
  /// Stores hdp width.
  int _hdpWidth = 0;

  // Height of the patterns in the pattern dictionary
  /// Stores hdp height.
  int _hdpHeight = 0;

  // Decoded bitmaps
  /// Stores patterns.
  List<_Jbig2Bitmap>? _patterns;

  // Largest gray-scale value
  /// Stores gray max.
  int _grayMax = 0;

  /// Creates the pattern dictionary state.
  _Jbig2PatternDictionary() : subInputStream = null;

  /// Parses header.
  void _parseHeader() {
    subInputStream!.readBits(5); // Dirty read

    _readTemplate();
    _readIsMMREncoded();
    _readPatternWidthAndHeight();
    _readGrayMax();
    _computeSegmentDataStructure();
    _checkInput();
  }

  /// Reads template.
  void _readTemplate() {
    _hdTemplate = subInputStream!.readBits(2);
  }

  /// Reads is mmrencoded.
  void _readIsMMREncoded() {
    if (subInputStream!.readBit() == 1) {
      _isMMREncoded = true;
    }
  }

  /// Reads pattern width and height.
  void _readPatternWidthAndHeight() {
    _hdpWidth = subInputStream!.read();
    _hdpHeight = subInputStream!.read();
  }

  /// Reads gray max.
  void _readGrayMax() {
    _grayMax = subInputStream!.readBits(32) & 0xffffffff;
  }

  /// Computes segment data structure.
  void _computeSegmentDataStructure() {
    _dataOffset = subInputStream!.getStreamPosition();
    _dataHeaderLength = _dataOffset - _dataHeaderOffset;
    _dataLength = subInputStream!.length - _dataHeaderLength;
  }

  /// Validates input.
  void _checkInput() {
    if (_hdpHeight < 1 || _hdpWidth < 1) {
      throw const ImageCodecException('Width/Height must be greater than zero.');
    }

    if (_isMMREncoded) {
      if (_hdTemplate != 0) {
        _Jbig2Log.info('hdTemplate should contain the value 0');
      }
    }
  }

  @override
  List<_Jbig2Bitmap> getDictionary() {
    if (_patterns == null) {
      if (!_isMMREncoded) {
        _setGbAtPixels();
      }

      final _Jbig2GenericRegion genericRegion = _Jbig2GenericRegion(subInputStream: subInputStream);
      genericRegion.setParametersForPattern(_isMMREncoded, _dataOffset, _dataLength, _hdpHeight, (_grayMax + 1) * _hdpWidth, _hdTemplate, false, null, _gbAtX, _gbAtY);

      final _Jbig2Bitmap collectiveBitmap = genericRegion.getRegionBitmap();
      _extractPatterns(collectiveBitmap);
    }
    return _patterns!;
  }

  /// Computes extract patterns.
  void _extractPatterns(_Jbig2Bitmap collectiveBitmap) {
    int gray = 0;
    _patterns = []; // Size hint not available in Dart List constructor like Java ArrayList

    while (gray <= _grayMax) {
      final _Jbig2Rectangle roi = _Jbig2Rectangle(x: _hdpWidth * gray, y: 0, width: _hdpWidth, height: _hdpHeight);
      final _Jbig2Bitmap patternBitmap = _Jbig2Bitmaps.extract(roi, collectiveBitmap);
      _patterns!.add(patternBitmap);
      gray++;
    }
  }

  /// Updates gb at pixels.
  void _setGbAtPixels() {
    if (_hdTemplate == 0) {
      _gbAtX = List.filled(4, 0);
      _gbAtY = List.filled(4, 0);
      _gbAtX![0] = -_hdpWidth;
      _gbAtY![0] = 0;
      _gbAtX![1] = -3;
      _gbAtY![1] = -1;
      _gbAtX![2] = 2;
      _gbAtY![2] = -2;
      _gbAtX![3] = -2;
      _gbAtY![3] = -2;
    } else {
      _gbAtX = List.filled(1, 0);
      _gbAtY = List.filled(1, 0);
      _gbAtX![0] = -_hdpWidth;
      _gbAtY![0] = 0;
    }
  }

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    subInputStream = sis;
    _parseHeader();
  }

  /// Returns is mmrencoded.
  bool get isMMREncoded => _isMMREncoded;

  /// Returns hd template.
  int get hdTemplate => _hdTemplate;

  /// Returns hdp width.
  int get hdpWidth => _hdpWidth;

  /// Returns hdp height.
  int get hdpHeight => _hdpHeight;

  /// Returns gray max.
  int get grayMax => _grayMax;
}
