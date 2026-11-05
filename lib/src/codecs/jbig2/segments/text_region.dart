// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 text region procedure.
class _Jbig2TextRegion implements _Jbig2Region {
  /// Stores sub input stream.
  _Jbig2BitReader? subInputStream;

  /// Stores region info.
  late _Jbig2RegionSegmentInformation _regionInfo;

  /// Stores segment header.
  _Jbig2Segment? segmentHeader;

  // Text region segment flags
  /// Stores sbr template.
  int _sbrTemplate = 0;

  /// Stores sbds offset.
  int _sbdsOffset = 0;

  /// Stores default pixel.
  int _defaultPixel = 0;

  /// Stores combination operator.
  _Jbig2CombinationOperator _combinationOperator = _Jbig2CombinationOperator.or;

  /// Stores is transposed.
  int _isTransposed = 0;

  /// Stores reference corner.
  int _referenceCorner = 0;

  /// Stores log sbstrips.
  int _logSBStrips = 0;

  /// Stores use refinement.
  bool _useRefinement = false;

  /// Stores is huffman encoded.
  bool _isHuffmanEncoded = false;

  // Text region segment Huffman flags
  /// Stores sb huff rsize.
  int _sbHuffRSize = 0;

  /// Stores sb huff rdy.
  int _sbHuffRDY = 0;

  /// Stores sb huff rdx.
  int _sbHuffRDX = 0;

  /// Stores sb huff rdheight.
  int _sbHuffRDHeight = 0;

  /// Stores sb huff rdwidth.
  int _sbHuffRDWidth = 0;

  /// Stores sb huff dt.
  int _sbHuffDT = 0;

  /// Stores sb huff ds.
  int _sbHuffDS = 0;

  /// Stores sb huff fs.
  int _sbHuffFS = 0;

  // Text region refinement AT flags
  /// Stores sbr atx.
  List<int>? _sbrATX;

  /// Stores sbr aty.
  List<int>? _sbrATY;

  /// Stores amount of symbol instances.
  int _amountOfSymbolInstances = 0;

  // Further parameters
  /// Stores current s.
  int _currentS = 0;

  /// Stores sb strips.
  int _sbStrips = 0;

  /// Stores amount of symbols.
  int _amountOfSymbols = 0;

  /// Stores region bitmap.
  _Jbig2Bitmap? _regionBitmap;

  /// Stores symbols.
  List<_Jbig2Bitmap> _symbols = [];

  /// Stores arithmetic decoder.
  _Jbig2ArithmeticDecoder? _arithmeticDecoder;

  /// Stores integer decoder.
  _Jbig2ArithmeticIntegerDecoder? _integerDecoder;

  /// Stores generic refinement region.
  _Jbig2GenericRefinementRegion? _genericRefinementRegion;

  /// Adaptive arithmetic state for the CX IADT context.
  _Jbig2ArithmeticContext? _cxIADT;

  /// Adaptive arithmetic state for the CX IAFS context.
  _Jbig2ArithmeticContext? _cxIAFS;

  /// Adaptive arithmetic state for the CX IADS context.
  _Jbig2ArithmeticContext? _cxIADS;

  /// Adaptive arithmetic state for the CX IAIT context.
  _Jbig2ArithmeticContext? _cxIAIT;

  /// Adaptive arithmetic state for the CX IARI context.
  _Jbig2ArithmeticContext? _cxIARI;

  /// Adaptive arithmetic state for the CX IARDW context.
  _Jbig2ArithmeticContext? _cxIARDW;

  /// Adaptive arithmetic state for the CX IARDH context.
  _Jbig2ArithmeticContext? _cxIARDH;

  /// Adaptive arithmetic state for the CX IAID context.
  _Jbig2ArithmeticContext? _cxIAID;

  /// Adaptive arithmetic state for the CX IARDX context.
  _Jbig2ArithmeticContext? _cxIARDX;

  /// Adaptive arithmetic state for the CX IARDY context.
  _Jbig2ArithmeticContext? _cxIARDY;

  /// Adaptive arithmetic state for the CX context.
  _Jbig2ArithmeticContext? _cx;

  /// Stores symbol code length.
  int _symbolCodeLength = 0;

  /// Stores symbol code table.
  _Jbig2FixedSizeTable? _symbolCodeTable;

  /// Stores fs table.
  _Jbig2HuffmanTable? _fsTable;

  /// Stores ds table.
  _Jbig2HuffmanTable? _dsTable;

  /// Stores table.
  _Jbig2HuffmanTable? table;

  /// Stores rdw table.
  _Jbig2HuffmanTable? _rdwTable;

  /// Stores rdh table.
  _Jbig2HuffmanTable? _rdhTable;

  /// Stores rdx table.
  _Jbig2HuffmanTable? _rdxTable;

  /// Stores rdy table.
  _Jbig2HuffmanTable? _rdyTable;

  /// Stores r size table.
  _Jbig2HuffmanTable? _rSizeTable;

  /// Creates the text region state.
  _Jbig2TextRegion({
    this.subInputStream,
    this.segmentHeader,
  }) {
    if (subInputStream != null) {
      _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    }
  }

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    segmentHeader = header;
    subInputStream = sis;
    _regionInfo = _Jbig2RegionSegmentInformation(subInputStream: subInputStream);
    _parseHeader();
  }

  /// Parses header.
  void _parseHeader() {
    _regionInfo.parseHeader();

    _readRegionFlags();

    if (_isHuffmanEncoded) {
      _readHuffmanFlags();
    }
    _readUseRefinement();

    _readAmountOfSymbolInstances();

    _getSymbols();

    _computeSymbolCodeLength();

    _checkInput();
  }

  /// Reads region flags.
  void _readRegionFlags() {
    _sbrTemplate = subInputStream!.readBit();
    _sbdsOffset = subInputStream!.readBits(5);
    if (_sbdsOffset > 0x0f) {
      _sbdsOffset -= 0x20;
    }
    _defaultPixel = subInputStream!.readBit();
    _combinationOperator = _Jbig2CombinationOperator.translateOperatorCodeToEnum(subInputStream!.readBits(2) & 0x3);
    _isTransposed = subInputStream!.readBit();
    _referenceCorner = subInputStream!.readBits(2) & 0x3;
    _logSBStrips = subInputStream!.readBits(2) & 0x3;
    _sbStrips = (1 << _logSBStrips);
    if (subInputStream!.readBit() == 1) {
      _useRefinement = true;
    }
    if (subInputStream!.readBit() == 1) {
      _isHuffmanEncoded = true;
    }
  }

  /// Reads huffman flags.
  void _readHuffmanFlags() {
    subInputStream!.readBit(); // Dirty read
    _sbHuffRSize = subInputStream!.readBit();
    _sbHuffRDY = subInputStream!.readBits(2) & 0xf;
    _sbHuffRDX = subInputStream!.readBits(2) & 0xf;
    _sbHuffRDHeight = subInputStream!.readBits(2) & 0xf;
    _sbHuffRDWidth = subInputStream!.readBits(2) & 0xf;
    _sbHuffDT = subInputStream!.readBits(2) & 0xf;
    _sbHuffDS = subInputStream!.readBits(2) & 0xf;
    _sbHuffFS = subInputStream!.readBits(2) & 0xf;
  }

  /// Reads use refinement.
  void _readUseRefinement() {
    if (_useRefinement && _sbrTemplate == 0) {
      _sbrATX = List.filled(2, 0);
      _sbrATY = List.filled(2, 0);
      _sbrATX![0] = subInputStream!.readBits(8).toSigned(8);
      _sbrATY![0] = subInputStream!.readBits(8).toSigned(8);
      _sbrATX![1] = subInputStream!.readBits(8).toSigned(8);
      _sbrATY![1] = subInputStream!.readBits(8).toSigned(8);
    }
  }

  /// Reads amount of symbol instances.
  void _readAmountOfSymbolInstances() {
    _amountOfSymbolInstances = _Jbig2Budget.reserve(subInputStream!.readBits(32), 8);
  }

  /// Returns symbols.
  void _getSymbols() {
    if (segmentHeader!.rtSegments.isNotEmpty) {
      _initSymbols();
    }
  }

  /// Initializes symbols.
  void _initSymbols() {
    for (final _Jbig2Segment segment in segmentHeader!.rtSegments) {
      if (segment.segmentType == 0) {
        final _Jbig2SymbolDictionary sd = segment.getSegmentData() as _Jbig2SymbolDictionary;
        sd.cxIAID = _cxIAID;
        _symbols.addAll(sd.getDictionary());
      }
    }
    _amountOfSymbols = _symbols.length;
  }

  /// Computes symbol code length.
  void _computeSymbolCodeLength() {
    if (_isHuffmanEncoded) {
      _symbolIDCodeLengths();
    } else {
      _symbolCodeLength = (math.log(_amountOfSymbols) / math.log(2)).ceil();
    }
  }

  /// Computes symbol idcode lengths.
  void _symbolIDCodeLengths() {
    final List<_Jbig2Code> runCodeTable = [];
    for (int i = 0; i < 35; i++) {
      final int prefLen = subInputStream!.readBits(4) & 0xf;
      if (prefLen > 0) {
        runCodeTable.add(_Jbig2Code(prefixLength: prefLen, rangeLength: 0, rangeLow: i, isLowerRange: false));
      }
    }

    final _Jbig2HuffmanTable ht = _Jbig2FixedSizeTable(runCodeTable: runCodeTable);

    int previousCodeLength = 0;
    int counter = 0;
    final List<_Jbig2Code> sbSymCodes = [];

    while (counter < _amountOfSymbols) {
      final int code = ht.decode(subInputStream!);
      if (code < 32) {
        if (code > 0) {
          sbSymCodes.add(_Jbig2Code(prefixLength: code, rangeLength: 0, rangeLow: counter, isLowerRange: false));
        }
        previousCodeLength = code;
        counter++;
      } else {
        int runLength = 0;
        int currCodeLength = 0;
        if (code == 32) {
          runLength = 3 + subInputStream!.readBits(2);
          if (counter > 0) {
            currCodeLength = previousCodeLength;
          }
        } else if (code == 33) {
          runLength = 3 + subInputStream!.readBits(3);
        } else if (code == 34) {
          runLength = 11 + subInputStream!.readBits(7);
        }

        for (int j = 0; j < runLength; j++) {
          if (currCodeLength > 0) {
            sbSymCodes.add(_Jbig2Code(prefixLength: currCodeLength, rangeLength: 0, rangeLow: counter, isLowerRange: false));
          }
          counter++;
        }
      }
    }
    subInputStream!.skipBits();
    _symbolCodeTable = _Jbig2FixedSizeTable(runCodeTable: sbSymCodes);
  }

  /// Validates input.
  void _checkInput() {
    if (!_useRefinement) {
      if (_sbrTemplate != 0) {
        _Jbig2Log.info('sbrTemplate should be 0');
        _sbrTemplate = 0;
      }
    }
    if (_sbHuffFS == 2 || _sbHuffRDWidth == 2 || _sbHuffRDHeight == 2 || _sbHuffRDX == 2 || _sbHuffRDY == 2) {
      throw const ImageCodecException('Huffman flag value of text region segment is not permitted');
    }
    if (!_useRefinement) {
      if (_sbHuffRSize != 0) {
        _Jbig2Log.info('sbHuffRSize should be 0');
        _sbHuffRSize = 0;
      }
      if (_sbHuffRDY != 0) {
        _Jbig2Log.info('sbHuffRDY should be 0');
        _sbHuffRDY = 0;
      }
      if (_sbHuffRDX != 0) {
        _Jbig2Log.info('sbHuffRDX should be 0');
        _sbHuffRDX = 0;
      }
      if (_sbHuffRDWidth != 0) {
        _Jbig2Log.info('sbHuffRDWidth should be 0');
        _sbHuffRDWidth = 0;
      }
      if (_sbHuffRDHeight != 0) {
        _Jbig2Log.info('sbHuffRDHeight should be 0');
        _sbHuffRDHeight = 0;
      }
    }
  }

  @override
  _Jbig2Bitmap getRegionBitmap() {
    if (!_isHuffmanEncoded) {
      _setCodingStatistics();
    }
    _createRegionBitmap();
    _decodeSymbolInstances();
    return _regionBitmap!;
  }

  @override
  _Jbig2RegionSegmentInformation getRegionInfo() => _regionInfo;

  /// Updates coding statistics.
  void _setCodingStatistics() {
    _cxIADT ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIAFS ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIADS ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIAIT ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIARI ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIARDW ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIARDH ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIAID ??= _Jbig2ArithmeticContext(size: 1 << _symbolCodeLength, index: 1);
    _cxIARDX ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIARDY ??= _Jbig2ArithmeticContext(size: 512, index: 1);

    _arithmeticDecoder ??= _Jbig2ArithmeticDecoder(iis: subInputStream!);
    _integerDecoder ??= _Jbig2ArithmeticIntegerDecoder(decoder: _arithmeticDecoder!);
  }

  /// Creates region bitmap.
  void _createRegionBitmap() {
    final int width = _regionInfo.bitmapWidth;
    final int height = _regionInfo.bitmapHeight;
    _regionBitmap = _Jbig2Bitmap(width: width, height: height);
    if (_defaultPixel != 0) {
      for (int i = 0; i < _regionBitmap!.getByteArray().length; i++) {
        _regionBitmap!.getByteArray()[i] = 0xff;
      }
    }
  }

  /// Decodes symbol instances.
  void _decodeSymbolInstances() {
    int stripT = _decodeStripT();

    int firstS = 0;
    int instanceCounter = 0;

    while (instanceCounter < _amountOfSymbolInstances) {
      final int dT = _decodeDT();
      stripT += dT;

      bool first = true;
      _currentS = 0;

      for (;;) {
        if (first) {
          final int dfS = _decodeDfS();
          firstS += dfS;
          _currentS = firstS;
          first = false;
        } else {
          final int idS = _decodeIdS();
          if (idS == 0x1fffffffffffff || instanceCounter >= _amountOfSymbolInstances) {
            break; // How to represent OOB?
          }

          _currentS += (idS + _sbdsOffset);
        }

        final int currentT = _decodeCurrentT();
        final int t = stripT + currentT;

        final int id = _decodeID();
        final int r = _decodeRI();
        final _Jbig2Bitmap ib = _decodeIb(r, id);

        _blit(ib, t);

        instanceCounter++;
      }
    }
  }

  /// Decodes strip t.
  int _decodeStripT() {
    int stripT = 0;
    if (_isHuffmanEncoded) {
      if (_sbHuffDT == 3) {
        if (table == null) {
          int dtNr = 0;
          if (_sbHuffFS == 3) {
            dtNr++;
          }
          if (_sbHuffDS == 3) {
            dtNr++;
          }
          table = _getUserTable(dtNr);
        }
        stripT = table!.decode(subInputStream!);
      } else {
        stripT = _Jbig2StandardTables.getTable(11 + _sbHuffDT).decode(subInputStream!);
      }
    } else {
      stripT = _integerDecoder!.decode(_cxIADT);
    }
    return stripT * -_sbStrips;
  }

  /// Decodes dt.
  int _decodeDT() {
    int dT;
    if (_isHuffmanEncoded) {
      if (_sbHuffDT == 3) {
        dT = table!.decode(subInputStream!);
      } else {
        dT = _Jbig2StandardTables.getTable(11 + _sbHuffDT).decode(subInputStream!);
      }
    } else {
      dT = _integerDecoder!.decode(_cxIADT);
    }
    return dT * _sbStrips;
  }

  /// Decodes df s.
  int _decodeDfS() {
    if (_isHuffmanEncoded) {
      if (_sbHuffFS == 3) {
        _fsTable ??= _getUserTable(0);
        return _fsTable!.decode(subInputStream!);
      } else {
        return _Jbig2StandardTables.getTable(6 + _sbHuffFS).decode(subInputStream!);
      }
    } else {
      return _integerDecoder!.decode(_cxIAFS);
    }
  }

  /// Decodes id s.
  int _decodeIdS() {
    if (_isHuffmanEncoded) {
      if (_sbHuffDS == 3) {
        if (_dsTable == null) {
          int dsNr = 0;
          if (_sbHuffFS == 3) {
            dsNr++;
          }
          _dsTable = _getUserTable(dsNr);
        }
        return _dsTable!.decode(subInputStream!);
      } else {
        return _Jbig2StandardTables.getTable(8 + _sbHuffDS).decode(subInputStream!);
      }
    } else {
      return _integerDecoder!.decode(_cxIADS);
    }
  }

  /// Decodes current t.
  int _decodeCurrentT() {
    if (_sbStrips != 1) {
      if (_isHuffmanEncoded) {
        return subInputStream!.readBits(_logSBStrips);
      } else {
        return _integerDecoder!.decode(_cxIAIT);
      }
    }
    return 0;
  }

  /// Decodes id.
  int _decodeID() {
    if (_isHuffmanEncoded) {
      if (_symbolCodeTable == null) {
        return subInputStream!.readBits(_symbolCodeLength);
      }
      return _symbolCodeTable!.decode(subInputStream!);
    } else {
      return _integerDecoder!.decodeIAID(_cxIAID!, _symbolCodeLength);
    }
  }

  /// Decodes ri.
  int _decodeRI() {
    if (_useRefinement) {
      if (_isHuffmanEncoded) {
        return subInputStream!.readBit();
      } else {
        return _integerDecoder!.decode(_cxIARI);
      }
    }
    return 0;
  }

  /// Decodes ib.
  _Jbig2Bitmap _decodeIb(int r, int id) {
    _Jbig2Bitmap ib;
    if (r == 0) {
      ib = _symbols[id];
    } else {
      final int rdw = _decodeRdw();
      final int rdh = _decodeRdh();
      final int rdx = _decodeRdx();
      final int rdy = _decodeRdy();

      if (_isHuffmanEncoded) {
        _decodeSymInRefSize();
        subInputStream!.skipBits();
      }

      final _Jbig2Bitmap ibo = _symbols[id];
      final int wo = ibo.width;
      final int ho = ibo.height;

      final int genericRegionReferenceDX = (rdw >> 1) + rdx;
      final int genericRegionReferenceDY = (rdh >> 1) + rdy;

      _genericRefinementRegion ??= _Jbig2GenericRefinementRegion(subInputStream: subInputStream);

      _genericRefinementRegion!.setParameters(_cx, _arithmeticDecoder, _sbrTemplate, (wo + rdw), (ho + rdh), ibo, genericRegionReferenceDX, genericRegionReferenceDY, false, _sbrATX, _sbrATY);

      ib = _genericRefinementRegion!.getRegionBitmap();

      if (_isHuffmanEncoded) {
        subInputStream!.skipBits();
      }
    }
    return ib;
  }

  /// Decodes rdw.
  int _decodeRdw() {
    if (_isHuffmanEncoded) {
      if (_sbHuffRDWidth == 3) {
        if (_rdwTable == null) {
          int rdwNr = 0;
          if (_sbHuffFS == 3) {
            rdwNr++;
          }
          if (_sbHuffDS == 3) {
            rdwNr++;
          }
          if (_sbHuffDT == 3) {
            rdwNr++;
          }
          _rdwTable = _getUserTable(rdwNr);
        }
        return _rdwTable!.decode(subInputStream!);
      } else {
        return _Jbig2StandardTables.getTable(14 + _sbHuffRDWidth).decode(subInputStream!);
      }
    } else {
      return _integerDecoder!.decode(_cxIARDW);
    }
  }

  /// Decodes rdh.
  int _decodeRdh() {
    if (_isHuffmanEncoded) {
      if (_sbHuffRDHeight == 3) {
        if (_rdhTable == null) {
          int rdhNr = 0;
          if (_sbHuffFS == 3) {
            rdhNr++;
          }
          if (_sbHuffDS == 3) {
            rdhNr++;
          }
          if (_sbHuffDT == 3) {
            rdhNr++;
          }
          if (_sbHuffRDWidth == 3) {
            rdhNr++;
          }
          _rdhTable = _getUserTable(rdhNr);
        }
        return _rdhTable!.decode(subInputStream!);
      } else {
        return _Jbig2StandardTables.getTable(14 + _sbHuffRDHeight).decode(subInputStream!);
      }
    } else {
      return _integerDecoder!.decode(_cxIARDH);
    }
  }

  /// Decodes rdx.
  int _decodeRdx() {
    if (_isHuffmanEncoded) {
      if (_sbHuffRDX == 3) {
        if (_rdxTable == null) {
          int rdxNr = 0;
          if (_sbHuffFS == 3) {
            rdxNr++;
          }
          if (_sbHuffDS == 3) {
            rdxNr++;
          }
          if (_sbHuffDT == 3) {
            rdxNr++;
          }
          if (_sbHuffRDWidth == 3) {
            rdxNr++;
          }
          if (_sbHuffRDHeight == 3) {
            rdxNr++;
          }
          _rdxTable = _getUserTable(rdxNr);
        }
        return _rdxTable!.decode(subInputStream!);
      } else {
        return _Jbig2StandardTables.getTable(14 + _sbHuffRDX).decode(subInputStream!);
      }
    } else {
      return _integerDecoder!.decode(_cxIARDX);
    }
  }

  /// Decodes rdy.
  int _decodeRdy() {
    if (_isHuffmanEncoded) {
      if (_sbHuffRDY == 3) {
        if (_rdyTable == null) {
          int rdyNr = 0;
          if (_sbHuffFS == 3) {
            rdyNr++;
          }
          if (_sbHuffDS == 3) {
            rdyNr++;
          }
          if (_sbHuffDT == 3) {
            rdyNr++;
          }
          if (_sbHuffRDWidth == 3) {
            rdyNr++;
          }
          if (_sbHuffRDHeight == 3) {
            rdyNr++;
          }
          if (_sbHuffRDX == 3) {
            rdyNr++;
          }
          _rdyTable = _getUserTable(rdyNr);
        }
        return _rdyTable!.decode(subInputStream!);
      } else {
        return _Jbig2StandardTables.getTable(14 + _sbHuffRDY).decode(subInputStream!);
      }
    } else {
      return _integerDecoder!.decode(_cxIARDY);
    }
  }

  /// Decodes sym in ref size.
  int _decodeSymInRefSize() {
    if (_sbHuffRSize == 0) {
      return _Jbig2StandardTables.getTable(1).decode(subInputStream!);
    } else {
      if (_rSizeTable == null) {
        int rSizeNr = 0;
        if (_sbHuffFS == 3) {
          rSizeNr++;
        }
        if (_sbHuffDS == 3) {
          rSizeNr++;
        }
        if (_sbHuffDT == 3) {
          rSizeNr++;
        }
        if (_sbHuffRDWidth == 3) {
          rSizeNr++;
        }
        if (_sbHuffRDHeight == 3) {
          rSizeNr++;
        }
        if (_sbHuffRDX == 3) {
          rSizeNr++;
        }
        if (_sbHuffRDY == 3) {
          rSizeNr++;
        }
        _rSizeTable = _getUserTable(rSizeNr);
      }
      return _rSizeTable!.decode(subInputStream!);
    }
  }

  /// Computes blit.
  void _blit(_Jbig2Bitmap ib, int initialT) {
    int t = initialT;
    if (_isTransposed == 0 && (_referenceCorner == 2 || _referenceCorner == 3)) {
      _currentS += ib.width - 1;
    } else if (_isTransposed == 1 && (_referenceCorner == 0 || _referenceCorner == 2)) {
      _currentS += ib.height - 1;
    }

    int s = _currentS;

    if (_isTransposed == 1) {
      final int swap = t;
      t = s;
      s = swap;
    }

    if (_referenceCorner != 1) {
      if (_referenceCorner == 0) {
        // BL
        t -= ib.height - 1;
      } else if (_referenceCorner == 2) {
        // BR
        t -= ib.height - 1;
        s -= ib.width - 1;
      } else if (_referenceCorner == 3) {
        // TR
        s -= ib.width - 1;
      }
    }

    _Jbig2Bitmaps.blit(ib, _regionBitmap!, s, t, _combinationOperator);

    if (_isTransposed == 0 && (_referenceCorner == 0 || _referenceCorner == 1)) {
      _currentS += ib.width - 1;
    }

    if (_isTransposed == 1 && (_referenceCorner == 1 || _referenceCorner == 3)) {
      _currentS += ib.height - 1;
    }
  }

  /// Returns user table.
  _Jbig2HuffmanTable? _getUserTable(int tablePosition) {
    int tableCounter = 0;
    for (final _Jbig2Segment referredToSegmentHeader in segmentHeader!.rtSegments) {
      if (referredToSegmentHeader.segmentType == 53) {
        if (tableCounter == tablePosition) {
          final _Jbig2Table t = referredToSegmentHeader.getSegmentData() as _Jbig2Table;
          return _Jbig2EncodedTable(table: t);
        } else {
          tableCounter++;
        }
      }
    }
    return null;
  }

  /// Updates contexts.
  void setContexts(
    _Jbig2ArithmeticContext cx,
    _Jbig2ArithmeticContext cxIADT,
    _Jbig2ArithmeticContext cxIAFS,
    _Jbig2ArithmeticContext cxIADS,
    _Jbig2ArithmeticContext cxIAIT,
    _Jbig2ArithmeticContext cxIAID,
    _Jbig2ArithmeticContext cxIARDW,
    _Jbig2ArithmeticContext cxIARDH,
    _Jbig2ArithmeticContext cxIARDX,
    _Jbig2ArithmeticContext cxIARDY,
  ) {
    _cx = cx;
    _cxIADT = cxIADT;
    _cxIAFS = cxIAFS;
    _cxIADS = cxIADS;
    _cxIAIT = cxIAIT;
    _cxIAID = cxIAID;
    _cxIARDW = cxIARDW;
    _cxIARDH = cxIARDH;
    _cxIARDX = cxIARDX;
    _cxIARDY = cxIARDY;
  }

  /// Updates parameters.
  void setParameters(
    _Jbig2ArithmeticDecoder arithmeticDecoder,
    _Jbig2ArithmeticIntegerDecoder iDecoder,
    bool isHuffmanEncoded,
    bool sbRefine,
    int sbw,
    int sbh,
    int sbNumInstances,
    int sbStrips,
    int sbNumSyms,
    int sbDefaultPixel,
    int sbCombinationOperator,
    int transposed,
    int refCorner,
    int sbdsOffset,
    int sbHuffFS,
    int sbHuffDS,
    int sbHuffDT,
    int sbHuffRDWidth,
    int sbHuffRDHeight,
    int sbHuffRDX,
    int sbHuffRDY,
    int sbHuffRSize,
    int sbrTemplate,
    List<int> sbrATX,
    List<int> sbrATY,
    List<_Jbig2Bitmap> sbSyms,
    int sbSymCodeLen,
  ) {
    _arithmeticDecoder = arithmeticDecoder;
    _integerDecoder = iDecoder;
    _isHuffmanEncoded = isHuffmanEncoded;
    _useRefinement = sbRefine;

    _regionInfo.bitmapWidth = sbw;
    _regionInfo.bitmapHeight = sbh;

    _amountOfSymbolInstances = sbNumInstances;
    _sbStrips = sbStrips;
    _amountOfSymbols = sbNumSyms;
    _defaultPixel = sbDefaultPixel;
    _combinationOperator = _Jbig2CombinationOperator.translateOperatorCodeToEnum(sbCombinationOperator);
    _isTransposed = transposed;
    _referenceCorner = refCorner;
    _sbdsOffset = sbdsOffset;

    _sbHuffFS = sbHuffFS;
    _sbHuffDS = sbHuffDS;
    _sbHuffDT = sbHuffDT;
    _sbHuffRDWidth = sbHuffRDWidth;
    _sbHuffRDHeight = sbHuffRDHeight;
    _sbHuffRDX = sbHuffRDX;
    _sbHuffRDY = sbHuffRDY;
    _sbHuffRSize = sbHuffRSize;

    _sbrTemplate = sbrTemplate;
    _sbrATX = sbrATX;
    _sbrATY = sbrATY;

    _symbols = sbSyms;
    _symbolCodeLength = sbSymCodeLen;
  }
}
