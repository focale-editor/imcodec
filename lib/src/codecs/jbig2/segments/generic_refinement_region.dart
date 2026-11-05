// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 template procedure.
abstract class _Jbig2Template {
  /// Computes form.
  int form(int c1, int c2, int c3, int c4, int c5);

  /// Updates index.
  void setIndex(_Jbig2ArithmeticContext cx);
}

/// Implements the JBIG2 template0 procedure.
class _Jbig2Template0 extends _Jbig2Template {
  @override
  int form(int c1, int c2, int c3, int c4, int c5) => (c1 << 10) | (c2 << 7) | (c3 << 4) | (c4 << 1) | c5;

  @override
  void setIndex(_Jbig2ArithmeticContext cx) {
    // Figure 14, page 22
    cx.setIndex(0x100);
  }
}

/// Implements the JBIG2 template1 procedure.
class _Jbig2Template1 extends _Jbig2Template {
  @override
  int form(int c1, int c2, int c3, int c4, int c5) => ((c1 & 0x02) << 8) | (c2 << 6) | ((c3 & 0x03) << 4) | (c4 << 1) | c5;

  @override
  void setIndex(_Jbig2ArithmeticContext cx) {
    // Figure 15, page 22
    cx.setIndex(0x080);
  }
}

/// Implements the JBIG2 generic refinement region procedure.
class _Jbig2GenericRefinementRegion implements _Jbig2Region {
  /// Stores t0.
  static final _Jbig2Template _t0 = _Jbig2Template0();

  /// Stores t1.
  static final _Jbig2Template _t1 = _Jbig2Template1();

  /// Stores sub input stream.
  _Jbig2BitReader? subInputStream;

  /// Stores segment header.
  _Jbig2Segment? segmentHeader;

  /// Stores region info.
  late _Jbig2RegionSegmentInformation _regionInfo;

  /// Stores is tpgron.
  bool _isTPGROn = false;

  /// Stores template id.
  int _templateID = 0;

  /// Stores template.
  _Jbig2Template? _template;

  /// Stores gr at x.
  List<int>? _grAtX;

  /// Stores gr at y.
  List<int>? _grAtY;

  /// Stores region bitmap.
  _Jbig2Bitmap? _regionBitmap;

  /// Stores reference bitmap.
  _Jbig2Bitmap? _referenceBitmap;

  /// Stores reference dx.
  int _referenceDX = 0;

  /// Stores reference dy.
  int _referenceDY = 0;

  /// Stores arith decoder.
  _Jbig2ArithmeticDecoder? _arithDecoder;

  /// Adaptive arithmetic state for the CX context.
  _Jbig2ArithmeticContext? _cx;

  /// Stores override.
  bool _override = false;

  /// Stores gr at override.
  List<bool>? _grAtOverride;

  /// Creates the generic refinement region state.
  _Jbig2GenericRefinementRegion({
    this.subInputStream,
  }) : segmentHeader = null {
    if (subInputStream != null) {
      _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    } else {
      _regionInfo = _Jbig2RegionSegmentInformation();
    }
  }

  /// Parses header.
  void parseHeader() {
    _regionInfo.parseHeader();

    /* Bit 2-7 */
    subInputStream!.readBits(6); // Dirty read...

    /* Bit 1 */
    if (subInputStream!.readBit() == 1) {
      _isTPGROn = true;
    }

    /* Bit 0 */
    _templateID = subInputStream!.readBit();

    switch (_templateID) {
      case 0:
        _template = _t0;
        _readAtPixels();
      case 1:
        _template = _t1;
    }
  }

  /// Reads at pixels.
  void _readAtPixels() {
    _grAtX = List.filled(2, 0);
    _grAtY = List.filled(2, 0);

    /* Byte 0 */
    _grAtX![0] = subInputStream!.readBits(8).toSigned(8);
    /* Byte 1 */
    _grAtY![0] = subInputStream!.readBits(8).toSigned(8);
    /* Byte 2 */
    _grAtX![1] = subInputStream!.readBits(8).toSigned(8);
    /* Byte 3 */
    _grAtY![1] = subInputStream!.readBits(8).toSigned(8);
  }

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    segmentHeader = header;
    subInputStream = sis;
    _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    parseHeader();
  }

  @override
  _Jbig2RegionSegmentInformation getRegionInfo() => _regionInfo;

  @override
  _Jbig2Bitmap getRegionBitmap() {
    if (_regionBitmap == null) {
      /* 6.3.5.6 - 1) */
      int isLineTypicalPredicted = 0;

      _referenceBitmap ??= _getGrReference();

      _arithDecoder ??= _Jbig2ArithmeticDecoder(iis: subInputStream!);

      _cx ??= _Jbig2ArithmeticContext(size: 8192, index: 1);

      /* 6.3.5.6 - 2) */
      _regionBitmap = _Jbig2Bitmap(width: _regionInfo.bitmapWidth, height: _regionInfo.bitmapHeight);

      if (_templateID == 0) {
        // AT pixel may only occur in template 0
        _updateOverride();
      }

      final int paddedWidth = (_regionBitmap!.width + 7) & -8;
      final int deltaRefStride = _isTPGROn ? -_referenceDY * _referenceBitmap!.rowStride : 0;
      final int yOffset = deltaRefStride + 1;

      /* 6.3.5.6 - 3 */
      for (int y = 0; y < _regionBitmap!.height; y++) {
        /* 6.3.5.6 - 3 b) */
        if (_isTPGROn) {
          isLineTypicalPredicted ^= _decodeSLTP();
        }

        if (isLineTypicalPredicted == 0) {
          /* 6.3.5.6 - 3 c) */
          _decodeOptimized(y, _regionBitmap!.width, _regionBitmap!.rowStride, _referenceBitmap!.rowStride, paddedWidth, deltaRefStride, yOffset);
        } else {
          /* 6.3.5.6 - 3 d) */
          _decodeTypicalPredictedLine(y, _regionBitmap!.width, _regionBitmap!.rowStride, _referenceBitmap!.rowStride, paddedWidth, deltaRefStride);
        }
      }
    }
    /* 6.3.5.6 - 4) */
    return _regionBitmap!;
  }

  /// Decodes sltp.
  int _decodeSLTP() {
    _template!.setIndex(_cx!);
    return _arithDecoder!.decode(_cx!);
  }

  /// Returns gr reference.
  _Jbig2Bitmap _getGrReference() {
    final List<_Jbig2Segment> segments = segmentHeader?.rtSegments ?? const [];
    for (final _Jbig2Segment referred in segments) {
      // region segment left behind.
      switch (referred.segmentType) {
        case 4: // Intermediate text region
        case 20: // Intermediate halftone region
        case 36: // Intermediate generic region
        case 40: // Intermediate generic refinement region
          return (referred.getSegmentData() as _Jbig2Region).getRegionBitmap();
      }
    }
    throw const FormatException(
      '8.2 5) d): the refinement region segment refers to no intermediate '
      'region, so it has no auxiliary buffer to refine',
    );
  }

  /// 8.2 5) c): makes the part of the page buffer this region covers the

  /// that refers to no intermediate region refines.
  void setPageAsReference(_Jbig2Bitmap pageArea) {
    _referenceBitmap = pageArea;
    _referenceDX = 0;
    _referenceDY = 0;
    _regionBitmap = null;
  }

  /// Decodes optimized.
  void _decodeOptimized(int lineNumber, int width, int rowStride, int refRowStride, int paddedWidth, int deltaRefStride, int lineOffset) {
    final int currentLine = lineNumber - _referenceDY;
    final int referenceByteIndex = _referenceBitmap!.getByteIndex(0 > -_referenceDX ? 0 : -_referenceDX, currentLine);

    final int byteIndex = _regionBitmap!.getByteIndex(0 > _referenceDX ? 0 : _referenceDX, lineNumber);

    switch (_templateID) {
      case 0:
        _decodeTemplate(lineNumber, width, rowStride, refRowStride, paddedWidth, deltaRefStride, lineOffset, byteIndex, currentLine, referenceByteIndex, _t0);
      case 1:
        _decodeTemplate(lineNumber, width, rowStride, refRowStride, paddedWidth, deltaRefStride, lineOffset, byteIndex, currentLine, referenceByteIndex, _t1);
    }
  }

  /// Decodes template.
  void _decodeTemplate(
    int lineNumber,
    int width,
    int rowStride,
    int refRowStride,
    int paddedWidth,
    int deltaRefStride,
    int lineOffset,
    int initialByteIndex,
    int currentLine,
    int initialRefByteIndex,
    _Jbig2Template templateFormation,
  ) {
    int refByteIndex = initialRefByteIndex;
    int byteIndex = initialByteIndex;
    int c1;
    int c2;
    int c3;
    int c4;
    int c5;

    int w1;
    int w2;
    int w3;
    int w4;
    w1 = w2 = w3 = w4 = 0;

    if (currentLine >= 1 && (currentLine - 1) < _referenceBitmap!.height) {
      w1 = _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride);
    }
    if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
      w2 = _referenceBitmap!.getByteAsInteger(refByteIndex);
    }
    if (currentLine >= -1 && currentLine + 1 < _referenceBitmap!.height) {
      w3 = _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride);
    }
    refByteIndex++;

    if (lineNumber >= 1) {
      w4 = _regionBitmap!.getByteAsInteger(byteIndex - rowStride);
    }
    byteIndex++;

    // T.88 reference offsets retain their sign when split across bytes.
    // Dart modulo normalizes negative offsets and selects the wrong context.
    final int modReferenceDX = _referenceDX.remainder(8);
    final int shiftOffset = 6 + modReferenceDX;
    final int modRefByteIdx = refByteIndex.remainder(refRowStride);

    if (shiftOffset >= 0) {
      c1 = ((shiftOffset >= 8 ? 0 : w1 >> shiftOffset) & 0x07);
      c2 = ((shiftOffset >= 8 ? 0 : w2 >> shiftOffset) & 0x07);
      c3 = ((shiftOffset >= 8 ? 0 : w3 >> shiftOffset) & 0x07);
      if (shiftOffset == 6 && modRefByteIdx > 1) {
        if (currentLine >= 1 && (currentLine - 1) < _referenceBitmap!.height) {
          c1 |= _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride - 2) << 2 & 0x04;
        }
        if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
          c2 |= _referenceBitmap!.getByteAsInteger(refByteIndex - 2) << 2 & 0x04;
        }
        if (currentLine >= -1 && currentLine + 1 < _referenceBitmap!.height) {
          c3 |= _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride - 2) << 2 & 0x04;
        }
      }
      if (shiftOffset == 0) {
        w1 = w2 = w3 = 0;
        if (modRefByteIdx < refRowStride - 1) {
          if (currentLine >= 1 && (currentLine - 1) < _referenceBitmap!.height) {
            w1 = _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride);
          }
          if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
            w2 = _referenceBitmap!.getByteAsInteger(refByteIndex);
          }
          if (currentLine >= -1 && currentLine + 1 < _referenceBitmap!.height) {
            w3 = _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride);
          }
        }
        refByteIndex++;
      }
    } else {
      c1 = ((w1 << 1) & 0x07);
      c2 = ((w2 << 1) & 0x07);
      c3 = ((w3 << 1) & 0x07);
      w1 = w2 = w3 = 0;
      if (modRefByteIdx < refRowStride - 1) {
        if (currentLine >= 1 && (currentLine - 1) < _referenceBitmap!.height) {
          w1 = _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride);
        }
        if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
          w2 = _referenceBitmap!.getByteAsInteger(refByteIndex);
        }
        if (currentLine >= -1 && currentLine + 1 < _referenceBitmap!.height) {
          w3 = _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride);
        }
        refByteIndex++;
      }
      c1 |= ((w1 >> 7) & 0x07);
      c2 |= ((w2 >> 7) & 0x07);
      c3 |= ((w3 >> 7) & 0x07);
    }

    c4 = (w4 >> 6);
    c5 = 0;

    final int modBitsToTrim = (2 - modReferenceDX).remainder(8);
    w1 <<= modBitsToTrim;
    w2 <<= modBitsToTrim;
    w3 <<= modBitsToTrim;

    w4 <<= 2;

    for (int x = 0; x < width; x++) {
      final int minorX = x & 0x07;

      final int tval = templateFormation.form(c1, c2, c3, c4, c5);

      if (_override) {
        _cx!.setIndex(_overrideAtTemplate0(tval, x, lineNumber, _regionBitmap!.getByte(_regionBitmap!.getByteIndex(x, lineNumber)), minorX));
      } else {
        _cx!.setIndex(tval);
      }
      final int bit = _arithDecoder!.decode(_cx!);
      _regionBitmap!.setPixel(x, lineNumber, bit);

      c1 = (((c1 << 1) | 0x01 & (w1 >> 7)) & 0x07);
      c2 = (((c2 << 1) | 0x01 & (w2 >> 7)) & 0x07);
      c3 = (((c3 << 1) | 0x01 & (w3 >> 7)) & 0x07);
      c4 = (((c4 << 1) | 0x01 & (w4 >> 7)) & 0x07);
      c5 = bit;

      if ((x - _referenceDX).remainder(8) == 5) {
        if (((x - _referenceDX) ~/ 8) + 1 >= _referenceBitmap!.rowStride) {
          w1 = w2 = w3 = 0;
        } else {
          if (currentLine >= 1 && (currentLine - 1 < _referenceBitmap!.height)) {
            w1 = _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride);
          } else {
            w1 = 0;
          }
          if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
            w2 = _referenceBitmap!.getByteAsInteger(refByteIndex);
          } else {
            w2 = 0;
          }
          if (currentLine >= -1 && (currentLine + 1) < _referenceBitmap!.height) {
            w3 = _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride);
          } else {
            w3 = 0;
          }
        }
        refByteIndex++;
      } else {
        w1 <<= 1;
        w2 <<= 1;
        w3 <<= 1;
      }

      if (minorX == 5 && lineNumber >= 1) {
        if ((x >> 3) + 1 >= _regionBitmap!.rowStride) {
          w4 = 0;
        } else {
          w4 = _regionBitmap!.getByteAsInteger(byteIndex - rowStride);
        }
        byteIndex++;
      } else {
        w4 <<= 1;
      }
    }
  }

  /// Computes update override.
  void _updateOverride() {
    if (_grAtX == null || _grAtY == null) {
      _Jbig2Log.info('AT pixels not set');
      return;
    }

    if (_grAtX!.length != _grAtY!.length) {
      _Jbig2Log.info('AT pixel inconsistent');
      return;
    }

    _grAtOverride = List.filled(_grAtX!.length, false);

    switch (_templateID) {
      case 0:
        if (_grAtX![0] != -1 && _grAtY![0] != -1) {
          _grAtOverride![0] = true;
          _override = true;
        }

        if (_grAtX![1] != -1 && _grAtY![1] != -1) {
          _grAtOverride![1] = true;
          _override = true;
        }
      case 1:
        _override = false;
    }
  }

  /// Decodes typical predicted line.
  void _decodeTypicalPredictedLine(int lineNumber, int width, int rowStride, int refRowStride, int paddedWidth, int deltaRefStride) {
    // decoded
    // For example: if grReferenceDY = -1, y is 1 HIGHER that currY
    final int currentLine = lineNumber - _referenceDY;
    final int refByteIndex = _referenceBitmap!.getByteIndex(0, currentLine);

    final int byteIndex = _regionBitmap!.getByteIndex(0, lineNumber);

    switch (_templateID) {
      case 0:
        _decodeTypicalPredictedLineTemplate0(lineNumber, width, rowStride, refRowStride, paddedWidth, deltaRefStride, byteIndex, currentLine, refByteIndex);
      case 1:
        _decodeTypicalPredictedLineTemplate1(lineNumber, width, rowStride, refRowStride, paddedWidth, deltaRefStride, byteIndex, currentLine, refByteIndex);
    }
  }

  /// Decodes typical predicted line template0.
  void _decodeTypicalPredictedLineTemplate0(
    int lineNumber,
    int width,
    int rowStride,
    int refRowStride,
    int paddedWidth,
    int deltaRefStride,
    int initialByteIndex,
    int currentLine,
    int initialRefByteIndex,
  ) {
    int refByteIndex = initialRefByteIndex;
    int byteIndex = initialByteIndex;
    int context;
    int overriddenContext;

    int previousLine;
    int previousReferenceLine;
    int currentReferenceLine;
    int nextReferenceLine;

    if (lineNumber > 0) {
      previousLine = _regionBitmap!.getByteAsInteger(byteIndex - rowStride);
    } else {
      previousLine = 0;
    }

    if (currentLine > 0 && currentLine <= _referenceBitmap!.height) {
      previousReferenceLine = _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride + deltaRefStride) << 4;
    } else {
      previousReferenceLine = 0;
    }

    if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
      currentReferenceLine = _referenceBitmap!.getByteAsInteger(refByteIndex + deltaRefStride) << 1;
    } else {
      currentReferenceLine = 0;
    }

    if (currentLine > -2 && currentLine < (_referenceBitmap!.height - 1)) {
      nextReferenceLine = _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride + deltaRefStride);
    } else {
      nextReferenceLine = 0;
    }

    context = ((previousLine >> 5) & 0x6) | ((nextReferenceLine >> 2) & 0x30) | (currentReferenceLine & 0x180) | (previousReferenceLine & 0xc00);

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      int result = 0;
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;
      final bool readNextByte = nextByte < width;
      final bool refReadNextByte = nextByte < _referenceBitmap!.width;

      final int yOffset = deltaRefStride + 1;

      if (lineNumber > 0) {
        previousLine = (previousLine << 8) | (readNextByte ? _regionBitmap!.getByteAsInteger(byteIndex - rowStride + 1) : 0);
      }

      if (currentLine > 0 && currentLine <= _referenceBitmap!.height) {
        previousReferenceLine = (previousReferenceLine << 8) | (refReadNextByte ? _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride + yOffset) << 4 : 0);
      }

      if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
        currentReferenceLine = (currentReferenceLine << 8) | (refReadNextByte ? _referenceBitmap!.getByteAsInteger(refByteIndex + yOffset) << 1 : 0);
      }

      if (currentLine > -2 && currentLine < (_referenceBitmap!.height - 1)) {
        nextReferenceLine = (nextReferenceLine << 8) | (refReadNextByte ? _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride + yOffset) : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        bool isPixelTypicalPredicted = false;
        int bit = 0;

        // i)
        final int bitmapValue = (context >> 4) & 0x1FF;

        if (bitmapValue == 0x1ff) {
          isPixelTypicalPredicted = true;
          bit = 1;
        } else if (bitmapValue == 0x00) {
          isPixelTypicalPredicted = true;
          bit = 0;
        }

        if (!isPixelTypicalPredicted) {
          // iii) - is like 3 c) but for one pixel only

          if (_override) {
            overriddenContext = _overrideAtTemplate0(context, x + minorX, lineNumber, result, minorX);
            _cx!.setIndex(overriddenContext);
          } else {
            _cx!.setIndex(context);
          }
          bit = _arithDecoder!.decode(_cx!);
        }

        final int toShift = 7 - minorX;
        result |= bit << toShift;

        context =
            ((context & 0xdb6) << 1) |
            bit |
            ((previousLine >> toShift + 5) & 0x002) |
            ((nextReferenceLine >> toShift + 2) & 0x010) |
            ((currentReferenceLine >> toShift) & 0x080) |
            ((previousReferenceLine >> toShift) & 0x400);
      }
      _regionBitmap!.setByte(byteIndex++, result);
      refByteIndex++;
    }
  }

  /// Decodes typical predicted line template1.
  void _decodeTypicalPredictedLineTemplate1(
    int lineNumber,
    int width,
    int rowStride,
    int refRowStride,
    int paddedWidth,
    int deltaRefStride,
    int initialByteIndex,
    int currentLine,
    int initialRefByteIndex,
  ) {
    int refByteIndex = initialRefByteIndex;
    int byteIndex = initialByteIndex;
    int context;
    int grReferenceValue;

    int previousLine;
    int previousReferenceLine;
    int currentReferenceLine;
    int nextReferenceLine;

    if (lineNumber > 0) {
      previousLine = _regionBitmap!.getByteAsInteger(byteIndex - rowStride);
    } else {
      previousLine = 0;
    }

    if (currentLine > 0 && currentLine <= _referenceBitmap!.height) {
      previousReferenceLine = _referenceBitmap!.getByteAsInteger(byteIndex - refRowStride + deltaRefStride) << 2;
    } else {
      previousReferenceLine = 0;
    }

    if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
      currentReferenceLine = _referenceBitmap!.getByteAsInteger(byteIndex + deltaRefStride);
    } else {
      currentReferenceLine = 0;
    }

    if (currentLine > -2 && currentLine < (_referenceBitmap!.height - 1)) {
      nextReferenceLine = _referenceBitmap!.getByteAsInteger(byteIndex + refRowStride + deltaRefStride);
    } else {
      nextReferenceLine = 0;
    }

    context = ((previousLine >> 5) & 0x6) | ((nextReferenceLine >> 2) & 0x30) | (currentReferenceLine & 0xc0) | (previousReferenceLine & 0x200);

    grReferenceValue = ((nextReferenceLine >> 2) & 0x70) | (currentReferenceLine & 0xc0) | (previousReferenceLine & 0x700);

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      int result = 0;
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;
      final bool readNextByte = nextByte < width;
      final bool refReadNextByte = nextByte < _referenceBitmap!.width;

      final int yOffset = deltaRefStride + 1;

      if (lineNumber > 0) {
        previousLine = (previousLine << 8) | (readNextByte ? _regionBitmap!.getByteAsInteger(byteIndex - rowStride + 1) : 0);
      }

      if (currentLine > 0 && currentLine <= _referenceBitmap!.height) {
        previousReferenceLine = (previousReferenceLine << 8) | (refReadNextByte ? _referenceBitmap!.getByteAsInteger(refByteIndex - refRowStride + yOffset) << 2 : 0);
      }

      if (currentLine >= 0 && currentLine < _referenceBitmap!.height) {
        currentReferenceLine = (currentReferenceLine << 8) | (refReadNextByte ? _referenceBitmap!.getByteAsInteger(refByteIndex + yOffset) : 0);
      }

      if (currentLine > -2 && currentLine < (_referenceBitmap!.height - 1)) {
        nextReferenceLine = (nextReferenceLine << 8) | (refReadNextByte ? _referenceBitmap!.getByteAsInteger(refByteIndex + refRowStride + yOffset) : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        int bit = 0;

        // i)
        final int bitmapValue = (grReferenceValue >> 4) & 0x1ff;

        if (bitmapValue == 0x1ff) {
          bit = 1;
        } else if (bitmapValue == 0x00) {
          bit = 0;
        } else {
          _cx!.setIndex(context);
          bit = _arithDecoder!.decode(_cx!);
        }

        final int toShift = 7 - minorX;
        result |= bit << toShift;

        context =
            ((context & 0x0d6) << 1) |
            bit |
            ((previousLine >> toShift + 5) & 0x002) |
            ((nextReferenceLine >> toShift + 2) & 0x010) |
            ((currentReferenceLine >> toShift) & 0x040) |
            ((previousReferenceLine >> toShift) & 0x200);

        grReferenceValue =
            ((grReferenceValue & 0x0db) << 1) | ((nextReferenceLine >> toShift + 2) & 0x010) | ((currentReferenceLine >> toShift) & 0x080) | ((previousReferenceLine >> toShift) & 0x400);
      }
      _regionBitmap!.setByte(byteIndex++, result);
      refByteIndex++;
    }
  }

  /// Computes override at template0.
  int _overrideAtTemplate0(int initialContext, int x, int y, int result, int minorX) {
    int context = initialContext;
    if (_grAtOverride![0]) {
      context &= 0xfff7;
      if (_grAtY![0] == 0 && _grAtX![0] >= -minorX) {
        context |= (result >> (7 - (minorX + _grAtX![0])) & 0x1) << 3;
      } else {
        context |= _getPixel(_regionBitmap!, x + _grAtX![0], y + _grAtY![0]) << 3;
      }
    }

    if (_grAtOverride![1]) {
      context &= 0xefff;
      if (_grAtY![1] == 0 && _grAtX![1] >= -minorX) {
        context |= (result >> (7 - (minorX + _grAtX![1])) & 0x1) << 12;
      } else {
        context |= _getPixel(_referenceBitmap!, x + _grAtX![1] + _referenceDX, y + _grAtY![1] + _referenceDY) << 12;
      }
    }
    return context;
  }

  /// Returns pixel.
  int _getPixel(_Jbig2Bitmap b, int x, int y) {
    if (x < 0 || x >= b.width) {
      return 0;
    }
    if (y < 0 || y >= b.height) {
      return 0;
    }

    return b.getPixel(x, y);
  }

  /// Updates parameters.
  void setParameters(
    _Jbig2ArithmeticContext? cx,
    _Jbig2ArithmeticDecoder? arithmeticDecoder,
    int grTemplate,
    int regionWidth,
    int regionHeight,
    _Jbig2Bitmap grReference,
    int grReferenceDX,
    int grReferenceDY,
    bool isTPGRon,
    List<int>? grAtX,
    List<int>? grAtY,
  ) {
    if (cx != null) {
      _cx = cx;
    }

    if (arithmeticDecoder != null) {
      _arithDecoder = arithmeticDecoder;
    }

    _templateID = grTemplate;

    _regionInfo.bitmapWidth = regionWidth;
    _regionInfo.bitmapHeight = regionHeight;

    _referenceBitmap = grReference;
    _referenceDX = grReferenceDX;
    _referenceDY = grReferenceDY;

    _isTPGROn = isTPGRon;

    _grAtX = grAtX;
    _grAtY = grAtY;

    _regionBitmap = null;

    if (_templateID == 0) {
      _template = _t0;
    } else {
      _template = _t1;
    }
  }
}
