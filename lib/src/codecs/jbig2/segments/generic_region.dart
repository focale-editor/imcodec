// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 generic region procedure.
class _Jbig2GenericRegion implements _Jbig2Region {
  /// Stores sub input stream.
  _Jbig2BitReader? subInputStream;

  /// Stores segment header.
  _Jbig2Segment? segmentHeader;

  /// Stores data header offset.
  final int _dataHeaderOffset = 0;

  /// Stores data offset.
  int _dataOffset = 0;

  /// Stores data length.
  int _dataLength = 0;

  /// Stores region info.
  _Jbig2RegionSegmentInformation? _regionInfo;

  /// Stores use ext templates.
  bool _useExtTemplates = false;

  /// Stores is tpgdon.
  bool _isTPGDon = false;

  /// Stores gb template.
  int _gbTemplate = 0;

  /// Stores is mmrencoded.
  bool _isMMREncoded = false;

  /// Stores gb at x.
  List<int>? _gbAtX;

  /// Stores gb at y.
  List<int>? _gbAtY;

  /// Stores gb at override.
  List<bool>? _gbAtOverride;

  /// Stores override.
  bool _override = false;

  /// 6.2.5.6 SKIP: a GBW by GBH mask whose set pixels are not decoded at all;
  /// the corresponding pixel of the region is 0. Null when USESKIP is 0.
  _Jbig2Bitmap? _skip;

  /// Stores region bitmap.
  _Jbig2Bitmap? _regionBitmap;

  /// Decodificador MMR reaproveitado entre planos de bits; veja
  /// [getRegionBitmap]. Zerado por `setParameters`, que troca a região.
  _Jbig2MmrDecoder? _mmrDecompressor;

  /// Stores arith decoder.
  _Jbig2ArithmeticDecoder? _arithDecoder;

  /// Adaptive arithmetic state for the CX context.
  _Jbig2ArithmeticContext? _cx;

  /// Creates the generic region state.
  _Jbig2GenericRegion({
    this.subInputStream,
  }) {
    if (subInputStream != null) {
      _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    }
  }

  /// Parses header.
  void _parseHeader() {
    _regionInfo!.parseHeader();

    /* Bit 5-7 */
    subInputStream!.readBits(3); // Dirty read...

    /* Bit 4 */
    if (subInputStream!.readBit() == 1) {
      _useExtTemplates = true;
    }

    /* Bit 3 */
    if (subInputStream!.readBit() == 1) {
      _isTPGDon = true;
    }

    /* Bit 1-2 */
    _gbTemplate = subInputStream!.readBits(2) & 0xf;

    /* Bit 0 */
    if (subInputStream!.readBit() == 1) {
      _isMMREncoded = true;
    }

    if (!_isMMREncoded) {
      final int amountOfGbAt;
      if (_gbTemplate == 0) {
        if (_useExtTemplates) {
          amountOfGbAt = 12;
        } else {
          amountOfGbAt = 4;
        }
      } else {
        amountOfGbAt = 1;
      }

      _readGbAtPixels(amountOfGbAt);
    }

    /* Segment data structure */
    _computeSegmentDataStructure();

    _clampHeightToRowCount();
  }

  /// 7.4.6.4: a segment that declared an unknown length (7.2.7) may hold fewer
  /// rows than its region segment information field announces. The real count
  /// sits in the last four bytes of the data part, and the region is that many
  /// rows tall.
  void _clampHeightToRowCount() {
    final _Jbig2Segment? header = segmentHeader;
    if (header == null || !header.hasUnknownDataLength) {
      return;
    }

    final int rows = header.unknownLengthRowCount;
    if (rows < 0 || rows > _regionInfo!.bitmapHeight) {
      throw FormatException(
        '7.4.6.4: the row count $rows of segment ${header.segmentNr} is not '
        'within its declared region height ${_regionInfo!.bitmapHeight}',
      );
    }
    _regionInfo!.bitmapHeight = rows;
  }

  /// Reads gb at pixels.
  void _readGbAtPixels(int amountOfGbAt) {
    _gbAtX = List<int>.filled(amountOfGbAt, 0);
    _gbAtY = List<int>.filled(amountOfGbAt, 0);

    for (int i = 0; i < amountOfGbAt; i++) {
      _gbAtX![i] = subInputStream!.readBits(8).toSigned(8);
      _gbAtY![i] = subInputStream!.readBits(8).toSigned(8);
    }
  }

  /// Computes segment data structure.
  void _computeSegmentDataStructure() {
    _dataOffset = subInputStream!.getStreamPosition();
    _dataLength = subInputStream!.length - (_dataOffset - _dataHeaderOffset);
  }

  @override
  _Jbig2Bitmap getRegionBitmap() {
    if (_regionBitmap == null) {
      if (_isMMREncoded) {
        if (_mmrDecompressor == null) {
          final _Jbig2ByteReader view = subInputStream!.wrappedStream.createView(subInputStream!.offset + _dataOffset, _dataLength);
          _mmrDecompressor = _Jbig2MmrDecoder(width: _regionInfo!.bitmapWidth, height: _regionInfo!.bitmapHeight, stream: view);
        }
        _regionBitmap = _mmrDecompressor!.uncompress();
      } else {
        _updateOverrideFlags();

        int ltp = 0;

        _arithDecoder ??= _Jbig2ArithmeticDecoder(iis: subInputStream!);
        _cx ??= _Jbig2ArithmeticContext(size: 65536, index: 1);

        _regionBitmap = _Jbig2Bitmap(width: _regionInfo!.bitmapWidth, height: _regionInfo!.bitmapHeight);

        final int paddedWidth = (_regionBitmap!.width + 7) & -8;

        for (int line = 0; line < _regionBitmap!.height; line++) {
          if (_isTPGDon) {
            ltp ^= _decodeSLTP();
          }

          if (ltp == 1) {
            if (line > 0) {
              _copyLineAbove(line);
            }
          } else {
            _decodeLine(line, _regionBitmap!.width, _regionBitmap!.rowStride, paddedWidth);
          }
        }
      }
    }
    return _regionBitmap!;
  }

  /// Decodes sltp.
  int _decodeSLTP() {
    switch (_gbTemplate) {
      case 0:
        _cx!.index = 0x9b25;
      case 1:
        _cx!.index = 0x795;
      case 2:
        _cx!.index = 0xe5;
      case 3:
        _cx!.index = 0x195;
    }
    return _arithDecoder!.decode(_cx!);
  }

  /// Decodes line.
  void _decodeLine(int lineNumber, int width, int rowStride, int paddedWidth) {
    final int byteIndex = _regionBitmap!.getByteIndex(0, lineNumber);
    final int idx = byteIndex - rowStride;

    switch (_gbTemplate) {
      case 0:
        if (!_useExtTemplates) {
          _decodeTemplate0a(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
        } else {
          _decodeTemplate0b(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
        }
      case 1:
        _decodeTemplate1(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
      case 2:
        _decodeTemplate2(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
      case 3:
        _decodeTemplate3(lineNumber, width, rowStride, paddedWidth, byteIndex, idx);
    }
  }

  /// Copies line above.
  void _copyLineAbove(int lineNumber) {
    int targetByteIndex = lineNumber * _regionBitmap!.rowStride;
    int sourceByteIndex = targetByteIndex - _regionBitmap!.rowStride;

    for (int i = 0; i < _regionBitmap!.rowStride; i++) {
      _regionBitmap!.setByte(targetByteIndex++, _regionBitmap!.getByte(sourceByteIndex++));
    }
  }

  /// Decodes template0a.
  void _decodeTemplate0a(int lineNumber, int width, int rowStride, int paddedWidth, int initialByteIndex, int initialIdx) {
    int idx = initialIdx;
    int byteIndex = initialByteIndex;
    int context;
    int overriddenContext = 0;

    int line1 = 0;
    int line2 = 0;

    if (lineNumber >= 1) {
      line1 = _regionBitmap!.getByte(idx);
    }

    if (lineNumber >= 2) {
      line2 = _regionBitmap!.getByte(idx - rowStride) << 6;
    }

    context = (line1 & 0xf0) | (line2 & 0x3800);

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      int result = 0;
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;

      if (lineNumber > 0) {
        line1 = (line1 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx + 1) : 0);
      }

      if (lineNumber > 1) {
        line2 = (line2 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx - rowStride + 1) << 6 : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        final int toShift = 7 - minorX;
        int bit;
        if (_isSkipped(x + minorX, lineNumber)) {
          bit = 0;
        } else {
          if (_override) {
            overriddenContext = _overrideAtTemplate0a(context, (x + minorX), lineNumber, result, minorX, toShift);
            _cx!.index = overriddenContext;
          } else {
            _cx!.index = context;
          }

          bit = _arithDecoder!.decode(_cx!);
        }

        result |= bit << toShift;

        context = ((context & 0x7bf7) << 1) | bit | ((line1 >> toShift) & 0x10) | ((line2 >> toShift) & 0x800);
      }

      _regionBitmap!.setByte(byteIndex++, result);
      idx++;
    }
  }

  /// Decodes template0b.
  void _decodeTemplate0b(int lineNumber, int width, int rowStride, int paddedWidth, int initialByteIndex, int initialIdx) {
    int idx = initialIdx;
    int byteIndex = initialByteIndex;
    int context;
    int overriddenContext = 0;

    int line1 = 0;
    int line2 = 0;

    if (lineNumber >= 1) {
      line1 = _regionBitmap!.getByte(idx);
    }

    if (lineNumber >= 2) {
      line2 = _regionBitmap!.getByte(idx - rowStride) << 6;
    }

    context = (line1 & 0xf0) | (line2 & 0x3800);

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      int result = 0;
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;

      if (lineNumber > 0) {
        line1 = (line1 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx + 1) : 0);
      }

      if (lineNumber > 1) {
        line2 = (line2 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx - rowStride + 1) << 6 : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        final int toShift = 7 - minorX;
        final int bit;
        if (_isSkipped(x + minorX, lineNumber)) {
          bit = 0;
        } else {
          if (_override) {
            overriddenContext = _overrideAtTemplate0b(context, (x + minorX), lineNumber, result, minorX, toShift);
            _cx!.index = overriddenContext;
          } else {
            _cx!.index = context;
          }

          bit = _arithDecoder!.decode(_cx!);
        }

        result |= bit << toShift;

        context = ((context & 0x7bf7) << 1) | bit | ((line1 >> toShift) & 0x10) | ((line2 >> toShift) & 0x800);
      }

      _regionBitmap!.setByte(byteIndex++, result);
      idx++;
    }
  }

  /// Decodes template1.
  void _decodeTemplate1(int lineNumber, int width, int rowStride, int paddedWidth, int initialByteIndex, int initialIdx) {
    int idx = initialIdx;
    int byteIndex = initialByteIndex;
    int context;
    int overriddenContext;

    int line1 = 0;
    int line2 = 0;

    if (lineNumber >= 1) {
      line1 = _regionBitmap!.getByte(idx);
    }

    if (lineNumber >= 2) {
      line2 = _regionBitmap!.getByte(idx - rowStride) << 5;
    }

    context = ((line1 >> 1) & 0x1f8) | ((line2 >> 1) & 0x1e00);

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      int result = 0;
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;

      if (lineNumber >= 1) {
        line1 = (line1 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx + 1) : 0);
      }

      if (lineNumber >= 2) {
        line2 = (line2 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx - rowStride + 1) << 5 : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        final int bit;
        if (_isSkipped(x + minorX, lineNumber)) {
          bit = 0;
        } else {
          if (_override) {
            overriddenContext = _overrideAtTemplate1(context, x + minorX, lineNumber, result, minorX);
            _cx!.index = overriddenContext;
          } else {
            _cx!.index = context;
          }

          bit = _arithDecoder!.decode(_cx!);
        }

        result |= bit << (7 - minorX);

        final int toShift = 8 - minorX;
        context = ((context & 0xefb) << 1) | bit | ((line1 >> toShift) & 0x8) | ((line2 >> toShift) & 0x200);
      }

      _regionBitmap!.setByte(byteIndex++, result);
      idx++;
    }
  }

  /// Decodes template2.
  void _decodeTemplate2(int lineNumber, int width, int rowStride, int paddedWidth, int initialByteIndex, int initialIdx) {
    int idx = initialIdx;
    int byteIndex = initialByteIndex;
    int context;
    int overriddenContext;

    int line1 = 0;
    int line2 = 0;

    if (lineNumber >= 1) {
      line1 = _regionBitmap!.getByte(idx);
    }

    if (lineNumber >= 2) {
      line2 = _regionBitmap!.getByte(idx - rowStride) << 4;
    }

    context = ((line1 >> 3) & 0x7c) | ((line2 >> 3) & 0x380);

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      int result = 0;
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;

      if (lineNumber >= 1) {
        line1 = (line1 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx + 1) : 0);
      }

      if (lineNumber >= 2) {
        line2 = (line2 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx - rowStride + 1) << 4 : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        final int bit;
        if (_isSkipped(x + minorX, lineNumber)) {
          bit = 0;
        } else {
          if (_override) {
            overriddenContext = _overrideAtTemplate2(context, x + minorX, lineNumber, result, minorX);
            _cx!.index = overriddenContext;
          } else {
            _cx!.index = context;
          }

          bit = _arithDecoder!.decode(_cx!);
        }

        result |= bit << (7 - minorX);

        final int toShift = 10 - minorX;
        context = ((context & 0x1bd) << 1) | bit | ((line1 >> toShift) & 0x4) | ((line2 >> toShift) & 0x80);
      }

      _regionBitmap!.setByte(byteIndex++, result);
      idx++;
    }
  }

  /// Decodes template3.
  void _decodeTemplate3(int lineNumber, int width, int rowStride, int paddedWidth, int initialByteIndex, int initialIdx) {
    int idx = initialIdx;
    int byteIndex = initialByteIndex;
    int context;
    int overriddenContext;

    int line1 = 0;

    if (lineNumber >= 1) {
      line1 = _regionBitmap!.getByte(idx);
    }

    context = (line1 >> 1) & 0x70;

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      int result = 0;
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;

      if (lineNumber >= 1) {
        line1 = (line1 << 8) | (nextByte < width ? _regionBitmap!.getByte(idx + 1) : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        final int bit;
        if (_isSkipped(x + minorX, lineNumber)) {
          bit = 0;
        } else {
          if (_override) {
            overriddenContext = _overrideAtTemplate3(context, x + minorX, lineNumber, result, minorX);
            _cx!.index = overriddenContext;
          } else {
            _cx!.index = context;
          }

          bit = _arithDecoder!.decode(_cx!);
        }

        result |= bit << (7 - minorX);
        context = ((context & 0x1f7) << 1) | bit | ((line1 >> (8 - minorX)) & 0x010);
      }

      _regionBitmap!.setByte(byteIndex++, result);
      idx++;
    }
  }

  /// Computes update override flags.
  void _updateOverrideFlags() {
    if (_gbAtX == null || _gbAtY == null) {
      return;
    }

    if (_gbAtX!.length != _gbAtY!.length) {
      return;
    }

    _gbAtOverride = List<bool>.filled(_gbAtX!.length, false);

    switch (_gbTemplate) {
      case 0:
        if (!_useExtTemplates) {
          if (_gbAtX![0] != 3 || _gbAtY![0] != -1) {
            _setOverrideFlag(0);
          }
          if (_gbAtX![1] != -3 || _gbAtY![1] != -1) {
            _setOverrideFlag(1);
          }
          if (_gbAtX![2] != 2 || _gbAtY![2] != -2) {
            _setOverrideFlag(2);
          }
          if (_gbAtX![3] != -2 || _gbAtY![3] != -2) {
            _setOverrideFlag(3);
          }
        } else {
          if (_gbAtX![0] != -2 || _gbAtY![0] != 0) {
            _setOverrideFlag(0);
          }
          if (_gbAtX![1] != 0 || _gbAtY![1] != -2) {
            _setOverrideFlag(1);
          }
          if (_gbAtX![2] != -2 || _gbAtY![2] != -1) {
            _setOverrideFlag(2);
          }
          if (_gbAtX![3] != -1 || _gbAtY![3] != -2) {
            _setOverrideFlag(3);
          }
          if (_gbAtX![4] != 1 || _gbAtY![4] != -2) {
            _setOverrideFlag(4);
          }
          if (_gbAtX![5] != 2 || _gbAtY![5] != -1) {
            _setOverrideFlag(5);
          }
          if (_gbAtX![6] != -3 || _gbAtY![6] != 0) {
            _setOverrideFlag(6);
          }
          if (_gbAtX![7] != -4 || _gbAtY![7] != 0) {
            _setOverrideFlag(7);
          }
          if (_gbAtX![8] != 2 || _gbAtY![8] != -2) {
            _setOverrideFlag(8);
          }
          if (_gbAtX![9] != 3 || _gbAtY![9] != -1) {
            _setOverrideFlag(9);
          }
          if (_gbAtX![10] != -2 || _gbAtY![10] != -2) {
            _setOverrideFlag(10);
          }
          if (_gbAtX![11] != -3 || _gbAtY![11] != -1) {
            _setOverrideFlag(11);
          }
        }
      case 1:
        if (_gbAtX![0] != 3 || _gbAtY![0] != -1) {
          _setOverrideFlag(0);
        }
      case 2:
        if (_gbAtX![0] != 2 || _gbAtY![0] != -1) {
          _setOverrideFlag(0);
        }
      case 3:
        if (_gbAtX![0] != 2 || _gbAtY![0] != -1) {
          _setOverrideFlag(0);
        }
    }
  }

  /// Updates override flag.
  void _setOverrideFlag(int index) {
    _gbAtOverride![index] = true;
    _override = true;
  }

  /// Computes override at template0a.
  int _overrideAtTemplate0a(int initialContext, int x, int y, int result, int minorX, int toShift) {
    int context = initialContext;
    if (_gbAtOverride![0]) {
      context &= 0xffef;
      if (_gbAtY![0] == 0 && _gbAtX![0] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![0]) & 0x1) << 4;
      } else {
        context |= _getPixel(x + _gbAtX![0], y + _gbAtY![0]) << 4;
      }
    }

    if (_gbAtOverride![1]) {
      context &= 0xfbff;
      if (_gbAtY![1] == 0 && _gbAtX![1] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![1]) & 0x1) << 10;
      } else {
        context |= _getPixel(x + _gbAtX![1], y + _gbAtY![1]) << 10;
      }
    }

    if (_gbAtOverride![2]) {
      context &= 0xf7ff;
      if (_gbAtY![2] == 0 && _gbAtX![2] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![2]) & 0x1) << 11;
      } else {
        context |= _getPixel(x + _gbAtX![2], y + _gbAtY![2]) << 11;
      }
    }

    if (_gbAtOverride![3]) {
      context &= 0x7fff;
      if (_gbAtY![3] == 0 && _gbAtX![3] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![3]) & 0x1) << 15;
      } else {
        context |= _getPixel(x + _gbAtX![3], y + _gbAtY![3]) << 15;
      }
    }
    return context;
  }

  /// Computes override at template0b.
  int _overrideAtTemplate0b(int initialContext, int x, int y, int result, int minorX, int toShift) {
    int context = initialContext;
    if (_gbAtOverride![0]) {
      context &= 0xfffd;
      if (_gbAtY![0] == 0 && _gbAtX![0] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![0]) & 0x1) << 1;
      } else {
        context |= _getPixel(x + _gbAtX![0], y + _gbAtY![0]) << 1;
      }
    }
    if (_gbAtOverride![1]) {
      context &= 0xdfff;
      if (_gbAtY![1] == 0 && _gbAtX![1] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![1]) & 0x1) << 13;
      } else {
        context |= _getPixel(x + _gbAtX![1], y + _gbAtY![1]) << 13;
      }
    }
    if (_gbAtOverride![2]) {
      context &= 0xfdff;
      if (_gbAtY![2] == 0 && _gbAtX![2] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![2]) & 0x1) << 9;
      } else {
        context |= _getPixel(x + _gbAtX![2], y + _gbAtY![2]) << 9;
      }
    }
    if (_gbAtOverride![3]) {
      context &= 0xbfff;
      if (_gbAtY![3] == 0 && _gbAtX![3] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![3]) & 0x1) << 14;
      } else {
        context |= _getPixel(x + _gbAtX![3], y + _gbAtY![3]) << 14;
      }
    }
    if (_gbAtOverride![4]) {
      context &= 0xefff;
      if (_gbAtY![4] == 0 && _gbAtX![4] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![4]) & 0x1) << 12;
      } else {
        context |= _getPixel(x + _gbAtX![4], y + _gbAtY![4]) << 12;
      }
    }
    if (_gbAtOverride![5]) {
      context &= 0xffdf;
      if (_gbAtY![5] == 0 && _gbAtX![5] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![5]) & 0x1) << 5;
      } else {
        context |= _getPixel(x + _gbAtX![5], y + _gbAtY![5]) << 5;
      }
    }
    if (_gbAtOverride![6]) {
      context &= 0xfffb;
      if (_gbAtY![6] == 0 && _gbAtX![6] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![6]) & 0x1) << 2;
      } else {
        context |= _getPixel(x + _gbAtX![6], y + _gbAtY![6]) << 2;
      }
    }
    if (_gbAtOverride![7]) {
      context &= 0xfff7;
      if (_gbAtY![7] == 0 && _gbAtX![7] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![7]) & 0x1) << 3;
      } else {
        context |= _getPixel(x + _gbAtX![7], y + _gbAtY![7]) << 3;
      }
    }
    if (_gbAtOverride![8]) {
      context &= 0xf7ff;
      if (_gbAtY![8] == 0 && _gbAtX![8] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![8]) & 0x1) << 11;
      } else {
        context |= _getPixel(x + _gbAtX![8], y + _gbAtY![8]) << 11;
      }
    }
    if (_gbAtOverride![9]) {
      context &= 0xffef;
      if (_gbAtY![9] == 0 && _gbAtX![9] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![9]) & 0x1) << 4;
      } else {
        context |= _getPixel(x + _gbAtX![9], y + _gbAtY![9]) << 4;
      }
    }
    if (_gbAtOverride![10]) {
      context &= 0x7fff;
      if (_gbAtY![10] == 0 && _gbAtX![10] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![10]) & 0x1) << 15;
      } else {
        context |= _getPixel(x + _gbAtX![10], y + _gbAtY![10]) << 15;
      }
    }
    if (_gbAtOverride![11]) {
      // A12 sits at bit 10 of the context, so bit 10 is the one to clear.

      // stream whose A12 was moved off its nominal (-3, -1) decoded to
      // garbage from the first pixel on.
      context &= 0xfbff;
      if (_gbAtY![11] == 0 && _gbAtX![11] >= -minorX) {
        context |= (result >> (toShift - _gbAtX![11]) & 0x1) << 10;
      } else {
        context |= _getPixel(x + _gbAtX![11], y + _gbAtY![11]) << 10;
      }
    }

    return context;
  }

  /// Computes override at template1.
  int _overrideAtTemplate1(int initialContext, int x, int y, int result, int minorX) {
    int context = initialContext;
    context &= 0x1ff7;
    if (_gbAtY![0] == 0 && _gbAtX![0] >= -minorX) {
      return (context | (result >> (7 - (minorX + _gbAtX![0])) & 0x1) << 3);
    } else {
      return (context | _getPixel(x + _gbAtX![0], y + _gbAtY![0]) << 3);
    }
  }

  /// Computes override at template2.
  int _overrideAtTemplate2(int initialContext, int x, int y, int result, int minorX) {
    int context = initialContext;
    context &= 0x3fb;
    if (_gbAtY![0] == 0 && _gbAtX![0] >= -minorX) {
      return (context | (result >> (7 - (minorX + _gbAtX![0])) & 0x1) << 2);
    } else {
      return (context | _getPixel(x + _gbAtX![0], y + _gbAtY![0]) << 2);
    }
  }

  /// Computes override at template3.
  int _overrideAtTemplate3(int initialContext, int x, int y, int result, int minorX) {
    int context = initialContext;
    context &= 0x3ef;
    if (_gbAtY![0] == 0 && _gbAtX![0] >= -minorX) {
      return (context | (result >> (7 - (minorX + _gbAtX![0])) & 0x1) << 4);
    } else {
      return (context | _getPixel(x + _gbAtX![0], y + _gbAtY![0]) << 4);
    }
  }

  /// 6.2.5.6: true when the pixel is masked out by SKIP and must be left at 0
  /// without consuming a decision from the arithmetic decoder.
  bool _isSkipped(int x, int y) {
    final _Jbig2Bitmap? skip = _skip;
    if (skip == null) {
      return false;
    }
    if (x >= skip.width || y >= skip.height) {
      return false;
    }
    return skip.getPixel(x, y) == 1;
  }

  /// Returns pixel.
  int _getPixel(int x, int y) {
    if (x < 0 || x >= _regionBitmap!.width) {
      return 0;
    }
    if (y < 0 || y >= _regionBitmap!.height) {
      return 0;
    }
    return _regionBitmap!.getPixel(x, y);
  }

  /// Updates parameters.
  void setParameters(
    bool isMMREncoded,
    int sdTemplate,
    bool isTPGDon,
    _Jbig2Bitmap? skip,
    List<int> sdATX,
    List<int> sdATY,
    int symWidth,
    int hcHeight,
    _Jbig2ArithmeticContext? cx,
    _Jbig2ArithmeticDecoder? arithmeticDecoder,
  ) {
    _skip = skip;
    _isMMREncoded = isMMREncoded;
    _gbTemplate = sdTemplate;
    _isTPGDon = isTPGDon;
    _gbAtX = sdATX;
    _gbAtY = sdATY;
    // A symbol dictionary always builds its _Jbig2GenericRegion around a stream, so
    // the region information field is there by the time this runs.
    _regionInfo!.bitmapWidth = symWidth;
    _regionInfo!.bitmapHeight = hcHeight;
    if (cx != null) {
      _cx = cx;
    }
    if (arithmeticDecoder != null) {
      _arithDecoder = arithmeticDecoder;
    }
    _mmrDecompressor = null;
    _regionBitmap = null;
  }

  /// Prepara a região para o bitmap coletivo de uma classe de altura, no
  /// dicionário de símbolos codificado em Huffman.
  ///
  /// Diferente de [setParametersForPattern], esta zera o decodificador MMR.
  /// Cada classe de altura é um fluxo MMR próprio, começando numa posição
  /// nova; reaproveitar o decodificador da classe anterior produziria o
  /// bitmap errado. Já a região halftone depende do reaproveitamento, porque
  /// seus planos de bits são consecutivos dentro de um mesmo fluxo — por isso

  void setParametersForCollectiveBitmap(bool isMMREncoded, int dataOffset, int dataLength, int gbh, int gbw) {
    _isMMREncoded = isMMREncoded;
    _dataOffset = dataOffset;
    _dataLength = dataLength;
    _regionInfo!.bitmapHeight = gbh;
    _regionInfo!.bitmapWidth = gbw;

    _mmrDecompressor = null;
    _regionBitmap = null;
  }

  /// Prepares the region for a pattern dictionary's collective bitmap or for
  /// one bit plane of a halftone region's grey-scale image.
  void setParametersForPattern(bool isMMREncoded, int dataOffset, int dataLength, int gbh, int gbw, int gbTemplate, bool isTPGDon, _Jbig2Bitmap? skip, List<int>? gbAtX, List<int>? gbAtY) {
    _skip = skip;
    _dataOffset = dataOffset;
    _dataLength = dataLength;

    _regionInfo = _Jbig2RegionSegmentInformation();
    _regionInfo!.bitmapHeight = gbh;
    _regionInfo!.bitmapWidth = gbw;
    _gbTemplate = gbTemplate;

    _isMMREncoded = isMMREncoded;
    _isTPGDon = isTPGDon;
    _gbAtX = gbAtX;
    _gbAtY = gbAtY;

    _regionBitmap = null;
  }

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    segmentHeader = header;
    subInputStream = sis;
    _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    _parseHeader();
  }

  @override
  _Jbig2RegionSegmentInformation getRegionInfo() => _regionInfo!;

  /// Resets bitmap.
  void resetBitmap() {
    _regionBitmap = null;
  }

  /// Returns use ext templates.
  bool get useExtTemplates => _useExtTemplates;

  /// Returns is mmrencoded.
  bool get isMMREncoded => _isMMREncoded;

  /// Returns gb template.
  int get gbTemplate => _gbTemplate;

  /// Returns is tpgdon.
  bool get isTPGDon => _isTPGDon;

  /// Returns gb at x.
  List<int>? get gbAtX => _gbAtX;

  /// Returns gb at y.
  List<int>? get gbAtY => _gbAtY;
}
