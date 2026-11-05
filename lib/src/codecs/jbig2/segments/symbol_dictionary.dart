// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 symbol dictionary procedure.
class _Jbig2SymbolDictionary implements _Jbig2Dictionary {
  /// Stores sub input stream.
  _Jbig2BitReader? subInputStream;

  /// Stores segment header.
  _Jbig2Segment? segmentHeader;

  // Symbol dictionary flags
  /// Stores sdr template.
  int _sdrTemplate = 0;

  /// Stores sd template.
  int _sdTemplate = 0;

  /// Stores is coding context retained.
  bool _isCodingContextRetained = false;

  /// Stores is coding context used.
  bool _isCodingContextUsed = false;

  /// Stores sd huff agg instance selection.
  int _sdHuffAggInstanceSelection = 0;

  /// Stores sd huff bmsize selection.
  int _sdHuffBMSizeSelection = 0;

  /// Stores sd huff decode width selection.
  int _sdHuffDecodeWidthSelection = 0;

  /// Stores sd huff decode height selection.
  int _sdHuffDecodeHeightSelection = 0;

  /// Stores use refinement aggregation.
  bool _useRefinementAggregation = false;

  /// Stores is huffman encoded.
  bool _isHuffmanEncoded = false;

  // Symbol dictionary AT flags
  /// Stores sd atx.
  List<int>? _sdATX;

  /// Stores sd aty.
  List<int>? _sdATY;

  // Symbol dictionary refinement AT flags
  /// Stores sdr atx.
  List<int>? _sdrATX;

  /// Stores sdr aty.
  List<int>? _sdrATY;

  /// Stores amount of export symbols.
  int _amountOfExportSymbols = 0;

  /// Stores amount of new symbols.
  int _amountOfNewSymbols = 0;

  /// Stores amount of imported symbols.
  int _amountOfImportedSymbols = 0;

  /// Stores import symbols.
  List<_Jbig2Bitmap> _importSymbols = [];

  /// Stores amount of decoded symbols.
  int _amountOfDecodedSymbols = 0;

  /// Stores new symbols.
  List<_Jbig2Bitmap?> _newSymbols = [];

  /// Stores dh table.
  _Jbig2HuffmanTable? _dhTable;

  /// Stores dw table.
  _Jbig2HuffmanTable? _dwTable;

  /// Stores bm size table.
  _Jbig2HuffmanTable? _bmSizeTable;

  /// Stores agg inst table.
  _Jbig2HuffmanTable? _aggInstTable;

  /// Stores export symbols.
  List<_Jbig2Bitmap>? _exportSymbols;

  /// Stores sb symbols.
  final List<_Jbig2Bitmap> _sbSymbols = [];

  /// Stores arithmetic decoder.
  _Jbig2ArithmeticDecoder? _arithmeticDecoder;

  /// Stores integer decoder.
  _Jbig2ArithmeticIntegerDecoder? _integerDecoder;

  /// Stores text region.
  _Jbig2TextRegion? _textRegion;

  /// Stores generic region.
  _Jbig2GenericRegion? _genericRegion;

  /// Stores generic refinement region.
  _Jbig2GenericRefinementRegion? _genericRefinementRegion;

  /// Adaptive arithmetic state for the CX context.
  _Jbig2ArithmeticContext? _cx;

  /// Adaptive arithmetic state for the CX IADH context.
  _Jbig2ArithmeticContext? _cxIADH;

  /// Adaptive arithmetic state for the CX IADW context.
  _Jbig2ArithmeticContext? _cxIADW;

  /// Adaptive arithmetic state for the CX IAAI context.
  _Jbig2ArithmeticContext? _cxIAAI;

  /// Adaptive arithmetic state for the CX IAEX context.
  _Jbig2ArithmeticContext? _cxIAEX;

  /// Adaptive arithmetic state for the CX IARDX context.
  _Jbig2ArithmeticContext? _cxIARDX;

  /// Adaptive arithmetic state for the CX IARDY context.
  _Jbig2ArithmeticContext? _cxIARDY;

  /// Adaptive arithmetic state for the CX IADT context.
  _Jbig2ArithmeticContext? _cxIADT;

  /// Adaptive arithmetic state for the CX IAID context.
  _Jbig2ArithmeticContext? cxIAID;

  /// Stores sb sym code len.
  int _sbSymCodeLen = 0;

  /// Creates the symbol dictionary state.
  _Jbig2SymbolDictionary() : segmentHeader = null, subInputStream = null;

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    subInputStream = sis;
    segmentHeader = header;
    _parseHeader();
  }

  /// Parses header.
  void _parseHeader() {
    _readRegionFlags();
    _setAtPixels();
    _setRefinementAtPixels();
    _readAmountOfExportedSymbols();
    _readAmountOfNewSymbols();
    _setInSyms();

    if (_isCodingContextUsed) {
      final List<_Jbig2Segment> rtSegments = segmentHeader!.rtSegments;
      for (int i = rtSegments.length - 1; i >= 0; i--) {
        if (rtSegments[i].segmentType == 0) {
          final _Jbig2SymbolDictionary symbolDictionary = rtSegments[i].getSegmentData() as _Jbig2SymbolDictionary;
          if (symbolDictionary._isCodingContextRetained) {
            _setRetainedCodingContexts(symbolDictionary);
          }
          break;
        }
      }
    }
    _checkInput();
  }

  /// Reads region flags.
  void _readRegionFlags() {
    subInputStream!.readBits(3); // Dirty read
    _sdrTemplate = subInputStream!.readBit();
    _sdTemplate = subInputStream!.readBits(2) & 0xf;
    if (subInputStream!.readBit() == 1) {
      _isCodingContextRetained = true;
    }
    if (subInputStream!.readBit() == 1) {
      _isCodingContextUsed = true;
    }
    _sdHuffAggInstanceSelection = subInputStream!.readBit();
    _sdHuffBMSizeSelection = subInputStream!.readBit();
    _sdHuffDecodeWidthSelection = subInputStream!.readBits(2) & 0xf;
    _sdHuffDecodeHeightSelection = subInputStream!.readBits(2) & 0xf;
    if (subInputStream!.readBit() == 1) {
      _useRefinementAggregation = true;
    }
    if (subInputStream!.readBit() == 1) {
      _isHuffmanEncoded = true;
    }
  }

  /// Updates at pixels.
  void _setAtPixels() {
    if (!_isHuffmanEncoded) {
      if (_sdTemplate == 0) {
        _readAtPixels(4);
      } else {
        _readAtPixels(1);
      }
    }
  }

  /// Updates refinement at pixels.
  void _setRefinementAtPixels() {
    if (_useRefinementAggregation && _sdrTemplate == 0) {
      _readRefinementAtPixels(2);
    }
  }

  /// Reads at pixels.
  void _readAtPixels(int amountOfPixels) {
    _sdATX = List.filled(amountOfPixels, 0);
    _sdATY = List.filled(amountOfPixels, 0);
    for (int i = 0; i < amountOfPixels; i++) {
      _sdATX![i] = subInputStream!.readBits(8).toSigned(8);
      _sdATY![i] = subInputStream!.readBits(8).toSigned(8);
    }
  }

  /// Reads refinement at pixels.
  void _readRefinementAtPixels(int amountOfAtPixels) {
    _sdrATX = List.filled(amountOfAtPixels, 0);
    _sdrATY = List.filled(amountOfAtPixels, 0);
    for (int i = 0; i < amountOfAtPixels; i++) {
      _sdrATX![i] = subInputStream!.readBits(8).toSigned(8);
      _sdrATY![i] = subInputStream!.readBits(8).toSigned(8);
    }
  }

  /// Reads amount of exported symbols.
  void _readAmountOfExportedSymbols() {
    _amountOfExportSymbols = subInputStream!.readBits(32);
  }

  /// Reads amount of new symbols.
  void _readAmountOfNewSymbols() {
    _amountOfNewSymbols = _Jbig2Budget.reserve(subInputStream!.readBits(32), 32);
  }

  /// Updates in syms.
  void _setInSyms() {
    if (segmentHeader!.rtSegments.isNotEmpty) {
      _retrieveImportSymbols();
    } else {
      _importSymbols = [];
    }
  }

  /// Updates retained coding contexts.
  void _setRetainedCodingContexts(_Jbig2SymbolDictionary sd) {
    _arithmeticDecoder = sd._arithmeticDecoder;
    _isHuffmanEncoded = sd._isHuffmanEncoded;
    _useRefinementAggregation = sd._useRefinementAggregation;
    _sdTemplate = sd._sdTemplate;
    _sdrTemplate = sd._sdrTemplate;
    _sdATX = sd._sdATX;
    _sdATY = sd._sdATY;
    _sdrATX = sd._sdrATX;
    _sdrATY = sd._sdrATY;
    _cx = sd._cx;
  }

  /// Validates input.
  void _checkInput() {
    if (_sdHuffDecodeHeightSelection == 2) {
      _Jbig2Log.info('sdHuffDecodeHeightSelection = $_sdHuffDecodeHeightSelection (value not permitted)');
    }
    if (_sdHuffDecodeWidthSelection == 2) {
      _Jbig2Log.info('sdHuffDecodeWidthSelection = $_sdHuffDecodeWidthSelection (value not permitted)');
    }
    if (_isHuffmanEncoded) {
      if (_sdTemplate != 0) {
        _Jbig2Log.info('sdTemplate = $_sdTemplate (should be 0)');
        _sdTemplate = 0;
      }
      if (!_useRefinementAggregation) {
        if (_isCodingContextRetained) {
          _Jbig2Log.info('isCodingContextRetained = $_isCodingContextRetained (should be 0)');
          _isCodingContextRetained = false;
        }
        if (_isCodingContextUsed) {
          _Jbig2Log.info('isCodingContextUsed = $_isCodingContextUsed (should be 0)');
          _isCodingContextUsed = false;
        }
      }
    } else {
      if (_sdHuffBMSizeSelection != 0) {
        _Jbig2Log.info('sdHuffBMSizeSelection should be 0');
        _sdHuffBMSizeSelection = 0;
      }
      if (_sdHuffDecodeWidthSelection != 0) {
        _Jbig2Log.info('sdHuffDecodeWidthSelection should be 0');
        _sdHuffDecodeWidthSelection = 0;
      }
      if (_sdHuffDecodeHeightSelection != 0) {
        _Jbig2Log.info('sdHuffDecodeHeightSelection should be 0');
        _sdHuffDecodeHeightSelection = 0;
      }
    }
    if (!_useRefinementAggregation) {
      if (_sdrTemplate != 0) {
        _Jbig2Log.info('sdrTemplate = $_sdrTemplate (should be 0)');
        _sdrTemplate = 0;
      }
    }
    if (!_isHuffmanEncoded || !_useRefinementAggregation) {
      if (_sdHuffAggInstanceSelection != 0) {
        _Jbig2Log.info('sdHuffAggInstanceSelection = $_sdHuffAggInstanceSelection (should be 0)');
        _sdHuffAggInstanceSelection = 0;
      }
    }
  }

  @override
  List<_Jbig2Bitmap> getDictionary() {
    if (_exportSymbols == null) {
      if (_useRefinementAggregation) {
        _sbSymCodeLen = _getSbSymCodeLen();
      }
      if (!_isHuffmanEncoded) {
        _setCodingStatistics();
      }

      _newSymbols = List.filled(_amountOfNewSymbols, null);
      List<int>? newSymbolsWidths;
      if (_isHuffmanEncoded && !_useRefinementAggregation) {
        newSymbolsWidths = List.filled(_amountOfNewSymbols, 0);
      }

      _setSymbolsArray();

      int heightClassHeight = 0;
      _amountOfDecodedSymbols = 0;

      while (_amountOfDecodedSymbols < _amountOfNewSymbols) {
        heightClassHeight += _decodeHeightClassDeltaHeight();
        int symbolWidth = 0;
        int totalWidth = 0;
        final int heightClassFirstSymbolIndex = _amountOfDecodedSymbols;

        while (true) {
          final int differenceWidth = _decodeDifferenceWidth();
          if (differenceWidth == 0x1fffffffffffff) {
            break;
          } // OOB check

          symbolWidth += differenceWidth;
          totalWidth += symbolWidth;

          if (!_isHuffmanEncoded || _useRefinementAggregation) {
            if (!_useRefinementAggregation) {
              _decodeDirectlyThroughGenericRegion(symbolWidth, heightClassHeight);
            } else {
              _decodeAggregate(symbolWidth, heightClassHeight);
            }
          } else if (_isHuffmanEncoded && !_useRefinementAggregation) {
            if (_amountOfDecodedSymbols < _amountOfNewSymbols) {
              newSymbolsWidths![_amountOfDecodedSymbols] = symbolWidth;
            }
          }
          _amountOfDecodedSymbols++;
        }

        if (_isHuffmanEncoded && !_useRefinementAggregation) {
          final int bmSize;
          if (_sdHuffBMSizeSelection == 0) {
            bmSize = _Jbig2StandardTables.getTable(1).decode(subInputStream!);
          } else {
            bmSize = _huffDecodeBmSize();
          }
          subInputStream!.skipBits();
          final _Jbig2Bitmap heightClassCollectiveBitmap = _decodeHeightClassCollectiveBitmap(bmSize, heightClassHeight, totalWidth);
          if (bmSize != 0) {
            subInputStream!.seek(subInputStream!.getStreamPosition() + bmSize);
          }
          subInputStream!.skipBits();
          _decodeHeightClassBitmap(heightClassCollectiveBitmap, heightClassFirstSymbolIndex, heightClassHeight, newSymbolsWidths!);
        }
      }
      final List<int> exFlags = _getToExportFlags();
      _setExportedSymbols(exFlags);
    }
    return _exportSymbols!;
  }

  /// Updates coding statistics.
  void _setCodingStatistics() {
    _cxIADT ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIADH ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIADW ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIAAI ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    _cxIAEX ??= _Jbig2ArithmeticContext(size: 512, index: 1);
    if (_useRefinementAggregation && cxIAID == null) {
      cxIAID = _Jbig2ArithmeticContext(size: 1 << _sbSymCodeLen, index: 1);
      _cxIARDX = _Jbig2ArithmeticContext(size: 512, index: 1);
      _cxIARDY = _Jbig2ArithmeticContext(size: 512, index: 1);
    }
    _cx ??= _Jbig2ArithmeticContext(size: 65536, index: 1);
    _arithmeticDecoder ??= _Jbig2ArithmeticDecoder(iis: subInputStream!);
    _integerDecoder ??= _Jbig2ArithmeticIntegerDecoder(decoder: _arithmeticDecoder!);
  }

  /// Decodes height class bitmap.
  void _decodeHeightClassBitmap(_Jbig2Bitmap heightClassCollectiveBitmap, int heightClassFirstSymbol, int heightClassHeight, List<int> newSymbolsWidths) {
    for (int i = heightClassFirstSymbol; i < _amountOfDecodedSymbols && i < _amountOfNewSymbols; i++) {
      int startColumn = 0;
      for (int j = heightClassFirstSymbol; j <= i - 1; j++) {
        startColumn += newSymbolsWidths[j];
      }
      final _Jbig2Rectangle roi = _Jbig2Rectangle(x: startColumn, y: 0, width: newSymbolsWidths[i], height: heightClassHeight);
      final _Jbig2Bitmap symbolBitmap = _Jbig2Bitmaps.extract(roi, heightClassCollectiveBitmap);
      _newSymbols[i] = symbolBitmap;
      _sbSymbols.add(symbolBitmap);
    }
  }

  /// Decodes aggregate.
  void _decodeAggregate(int symbolWidth, int heightClassHeight) {
    final int amountOfRefinementAggregationInstances;
    if (_isHuffmanEncoded) {
      amountOfRefinementAggregationInstances = _huffDecodeRefAggNInst();
    } else {
      amountOfRefinementAggregationInstances = _integerDecoder!.decode(_cxIAAI);
    }

    if (amountOfRefinementAggregationInstances > 1) {
      _decodeThroughTextRegion(symbolWidth, heightClassHeight, amountOfRefinementAggregationInstances);
    } else if (amountOfRefinementAggregationInstances == 1) {
      _decodeRefinedSymbol(symbolWidth, heightClassHeight);
    }
  }

  /// Computes huff decode ref agg ninst.
  int _huffDecodeRefAggNInst() {
    if (_sdHuffAggInstanceSelection == 0) {
      return _Jbig2StandardTables.getTable(1).decode(subInputStream!);
    } else if (_sdHuffAggInstanceSelection == 1) {
      if (_aggInstTable == null) {
        int aggregationInstanceNumber = 0;
        if (_sdHuffDecodeHeightSelection == 3) {
          aggregationInstanceNumber++;
        }
        if (_sdHuffDecodeWidthSelection == 3) {
          aggregationInstanceNumber++;
        }
        if (_sdHuffBMSizeSelection == 3) {
          aggregationInstanceNumber++;
        }
        _aggInstTable = _getUserTable(aggregationInstanceNumber);
      }
      return _aggInstTable!.decode(subInputStream!);
    }
    return 0;
  }

  /// Decodes through text region.
  void _decodeThroughTextRegion(int symbolWidth, int heightClassHeight, int amountOfRefinementAggregationInstances) {
    if (_textRegion == null) {
      _textRegion = _Jbig2TextRegion(subInputStream: subInputStream, segmentHeader: null);
      _textRegion!.setContexts(
        _cx!,
        _Jbig2ArithmeticContext(size: 512, index: 1),
        _Jbig2ArithmeticContext(size: 512, index: 1),
        _Jbig2ArithmeticContext(size: 512, index: 1),
        _Jbig2ArithmeticContext(size: 512, index: 1),
        cxIAID!,
        _Jbig2ArithmeticContext(size: 512, index: 1),
        _Jbig2ArithmeticContext(size: 512, index: 1),
        _Jbig2ArithmeticContext(size: 512, index: 1),
        _Jbig2ArithmeticContext(size: 512, index: 1),
      );
    }
    _setSymbolsArray();
    _textRegion!.setParameters(
      _arithmeticDecoder!,
      _integerDecoder!,
      _isHuffmanEncoded,
      true,
      symbolWidth,
      heightClassHeight,
      amountOfRefinementAggregationInstances,
      1,
      (_amountOfImportedSymbols + _amountOfDecodedSymbols),
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      _sdrTemplate,
      _sdrATX!,
      _sdrATY!,
      _sbSymbols,
      _sbSymCodeLen,
    );
    _addSymbol(_textRegion!);
  }

  /// Decodes refined symbol.
  void _decodeRefinedSymbol(int symbolWidth, int heightClassHeight) {
    final int id;
    final int rdx;
    final int rdy;
    if (_isHuffmanEncoded) {
      id = subInputStream!.readBits(_sbSymCodeLen);
      rdx = _Jbig2StandardTables.getTable(15).decode(subInputStream!);
      rdy = _Jbig2StandardTables.getTable(15).decode(subInputStream!);
      _Jbig2StandardTables.getTable(1).decode(subInputStream!);
      subInputStream!.skipBits();
    } else {
      id = _integerDecoder!.decodeIAID(cxIAID!, _sbSymCodeLen);
      rdx = _integerDecoder!.decode(_cxIARDX);
      rdy = _integerDecoder!.decode(_cxIARDY);
    }
    _setSymbolsArray();
    final _Jbig2Bitmap ibo = _sbSymbols[id];
    _decodeNewSymbols(symbolWidth, heightClassHeight, ibo, rdx, rdy);
    if (_isHuffmanEncoded) {
      subInputStream!.skipBits();
    }
  }

  /// Decodes new symbols.
  void _decodeNewSymbols(int symWidth, int hcHeight, _Jbig2Bitmap ibo, int rdx, int rdy) {
    if (_genericRefinementRegion == null) {
      _genericRefinementRegion = _Jbig2GenericRefinementRegion(subInputStream: subInputStream);
      _arithmeticDecoder ??= _Jbig2ArithmeticDecoder(iis: subInputStream!);
      _cx ??= _Jbig2ArithmeticContext(size: 65536, index: 1);
    }
    _genericRefinementRegion!.setParameters(_cx, _arithmeticDecoder, _sdrTemplate, symWidth, hcHeight, ibo, rdx, rdy, false, _sdrATX, _sdrATY);
    _addSymbol(_genericRefinementRegion!);
  }

  /// Decodes directly through generic region.
  void _decodeDirectlyThroughGenericRegion(int symWidth, int hcHeight) {
    _genericRegion ??= _Jbig2GenericRegion(subInputStream: subInputStream);
    _genericRegion!.setParameters(false, _sdTemplate, false, null, _sdATX!, _sdATY!, symWidth, hcHeight, _cx, _arithmeticDecoder);
    _addSymbol(_genericRegion!);
  }

  /// Computes add symbol.
  void _addSymbol(_Jbig2Region region) {
    final _Jbig2Bitmap symbol = region.getRegionBitmap();
    _newSymbols[_amountOfDecodedSymbols] = symbol;
    _sbSymbols.add(symbol);
  }

  /// Decodes difference width.
  int _decodeDifferenceWidth() {
    if (_isHuffmanEncoded) {
      switch (_sdHuffDecodeWidthSelection) {
        case 0:
          return _Jbig2StandardTables.getTable(2).decode(subInputStream!);
        case 1:
          return _Jbig2StandardTables.getTable(3).decode(subInputStream!);
        case 3:
          if (_dwTable == null) {
            int dwNr = 0;
            if (_sdHuffDecodeHeightSelection == 3) {
              dwNr++;
            }
            _dwTable = _getUserTable(dwNr);
          }
          return _dwTable!.decode(subInputStream!);
      }
    } else {
      return _integerDecoder!.decode(_cxIADW);
    }
    return 0;
  }

  /// Decodes height class delta height.
  int _decodeHeightClassDeltaHeight() {
    if (_isHuffmanEncoded) {
      return _decodeHeightClassDeltaHeightWithHuffman();
    } else {
      return _integerDecoder!.decode(_cxIADH);
    }
  }

  /// Decodes height class delta height with huffman.
  int _decodeHeightClassDeltaHeightWithHuffman() {
    switch (_sdHuffDecodeHeightSelection) {
      case 0:
        return _Jbig2StandardTables.getTable(4).decode(subInputStream!);
      case 1:
        return _Jbig2StandardTables.getTable(5).decode(subInputStream!);
      case 3:
        _dhTable ??= _getUserTable(0);
        return _dhTable!.decode(subInputStream!);
    }
    return 0;
  }

  /// Decodes height class collective bitmap.
  _Jbig2Bitmap _decodeHeightClassCollectiveBitmap(int bmSize, int heightClassHeight, int totalWidth) {
    if (bmSize == 0) {
      final _Jbig2Bitmap heightClassCollectiveBitmap = _Jbig2Bitmap(width: totalWidth, height: heightClassHeight);
      for (int i = 0; i < heightClassCollectiveBitmap.getByteArray().length; i++) {
        heightClassCollectiveBitmap.setByte(i, subInputStream!.read());
      }
      return heightClassCollectiveBitmap;
    } else {
      _genericRegion ??= _Jbig2GenericRegion(subInputStream: subInputStream);
      _genericRegion!.setParametersForCollectiveBitmap(true, subInputStream!.getStreamPosition(), bmSize, heightClassHeight, totalWidth);
      return _genericRegion!.getRegionBitmap();
    }
  }

  /// Updates exported symbols.
  void _setExportedSymbols(List<int> toExportFlags) {
    _exportSymbols = [];
    for (int i = 0; i < _amountOfImportedSymbols + _amountOfNewSymbols; i++) {
      if (toExportFlags[i] == 1) {
        if (i < _amountOfImportedSymbols) {
          _exportSymbols!.add(_importSymbols[i]);
        } else {
          _exportSymbols!.add(_newSymbols[i - _amountOfImportedSymbols]!);
        }
      }
    }
  }

  /// Returns to export flags.
  List<int> _getToExportFlags() {
    int currentExportFlag = 0;
    int exRunLength = 0;
    bool previousRunWasEmpty = false;
    final List<int> exportFlags = List.filled(_amountOfImportedSymbols + _amountOfNewSymbols, 0);
    for (int exportIndex = 0; exportIndex < _amountOfImportedSymbols + _amountOfNewSymbols; exportIndex += exRunLength) {
      if (_isHuffmanEncoded) {
        exRunLength = _Jbig2StandardTables.getTable(1).decode(subInputStream!);
      } else {
        exRunLength = _integerDecoder!.decode(_cxIAEX);
      }
      if (exRunLength < 0 || exRunLength > exportFlags.length - exportIndex || (exRunLength == 0 && previousRunWasEmpty)) {
        throw const ImageCodecException('Invalid JBIG2 symbol export run');
      }
      previousRunWasEmpty = exRunLength == 0;
      if (exRunLength != 0) {
        for (int index = exportIndex; index < exportIndex + exRunLength; index++) {
          if (index < exportFlags.length) {
            exportFlags[index] = currentExportFlag;
          }
        }
      }
      currentExportFlag = (currentExportFlag == 0) ? 1 : 0;
    }
    return exportFlags;
  }

  /// Computes huff decode bm size.
  int _huffDecodeBmSize() {
    if (_bmSizeTable == null) {
      int bmNr = 0;
      if (_sdHuffDecodeHeightSelection == 3) {
        bmNr++;
      }
      if (_sdHuffDecodeWidthSelection == 3) {
        bmNr++;
      }
      _bmSizeTable = _getUserTable(bmNr);
    }
    return _bmSizeTable!.decode(subInputStream!);
  }

  /// Returns sb sym code len.
  int _getSbSymCodeLen() {
    if (_isHuffmanEncoded) {
      return math.max((math.log(_amountOfImportedSymbols + _amountOfNewSymbols) / math.log(2)).ceil(), 1);
    } else {
      return (math.log(_amountOfImportedSymbols + _amountOfNewSymbols) / math.log(2)).ceil();
    }
  }

  /// Updates symbols array.
  void _setSymbolsArray() {
    if (_importSymbols.isEmpty && segmentHeader!.rtSegments.isNotEmpty) {
      _retrieveImportSymbols();
    }
    if (_sbSymbols.isEmpty) {
      _sbSymbols.addAll(_importSymbols);
    }
  }

  /// Computes retrieve import symbols.
  void _retrieveImportSymbols() {
    _importSymbols = [];
    for (final _Jbig2Segment referredToSegmentHeader in segmentHeader!.rtSegments) {
      if (referredToSegmentHeader.segmentType == 0) {
        final _Jbig2SymbolDictionary sd = referredToSegmentHeader.getSegmentData() as _Jbig2SymbolDictionary;
        _importSymbols.addAll(sd.getDictionary());
        _amountOfImportedSymbols += sd._amountOfExportSymbols;
      }
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
}
