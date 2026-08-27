part of '../../webp.dart';

/// Decodes the lossless VP8L pixel representation used by WebP.
final class _Vp8LosslessDecoder {
  /// Huffman-tree index for green and length symbols.
  static const int _green = 0;

  /// Huffman-tree index for red symbols.
  static const int _red = 1;

  /// Huffman-tree index for blue symbols.
  static const int _blue = 2;

  /// Huffman-tree index for alpha symbols.
  static const int _alpha = 3;

  /// Huffman-tree index for distance symbols.
  static const int _dist = 4;

  /// Number of decoded rows kept in the rolling pixel cache.
  static const int _pixelCacheRowCount = 16;

  /// Number of symbols in the code-length alphabet.
  static const int _numCodeLengthCodes = 19;

  /// Permutation used to read code-length code lengths.
  static const List<int> _codeLengthCodeOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

  /// Number of compact two-dimensional distance codes.
  static const int _codeToPlaneCodes = 120;

  /// Maps compact distance codes to signed horizontal and vertical offsets.
  static const List<int> _codeToPlane = [
    0x18,
    0x07,
    0x17,
    0x19,
    0x28,
    0x06,
    0x27,
    0x29,
    0x16,
    0x1a,
    0x26,
    0x2a,
    0x38,
    0x05,
    0x37,
    0x39,
    0x15,
    0x1b,
    0x36,
    0x3a,
    0x25,
    0x2b,
    0x48,
    0x04,
    0x47,
    0x49,
    0x14,
    0x1c,
    0x35,
    0x3b,
    0x46,
    0x4a,
    0x24,
    0x2c,
    0x58,
    0x45,
    0x4b,
    0x34,
    0x3c,
    0x03,
    0x57,
    0x59,
    0x13,
    0x1d,
    0x56,
    0x5a,
    0x23,
    0x2d,
    0x44,
    0x4c,
    0x55,
    0x5b,
    0x33,
    0x3d,
    0x68,
    0x02,
    0x67,
    0x69,
    0x12,
    0x1e,
    0x66,
    0x6a,
    0x22,
    0x2e,
    0x54,
    0x5c,
    0x43,
    0x4d,
    0x65,
    0x6b,
    0x32,
    0x3e,
    0x78,
    0x01,
    0x77,
    0x79,
    0x53,
    0x5d,
    0x11,
    0x1f,
    0x64,
    0x6c,
    0x42,
    0x4e,
    0x76,
    0x7a,
    0x21,
    0x2f,
    0x75,
    0x7b,
    0x31,
    0x3f,
    0x63,
    0x6d,
    0x52,
    0x5e,
    0x00,
    0x74,
    0x7c,
    0x41,
    0x4f,
    0x10,
    0x20,
    0x62,
    0x6e,
    0x30,
    0x73,
    0x7d,
    0x51,
    0x5f,
    0x40,
    0x72,
    0x7e,
    0x61,
    0x6f,
    0x50,
    0x71,
    0x7f,
    0x60,
    0x70,
  ];

  /// Number of literal code-length symbols.
  static const int _codeLengthLiterals = 16;

  /// First symbol that repeats a previous code length.
  static const int _codeLengthRepeatCode = 16;

  /// Extra-bit counts for repeat symbols 16 through 18.
  static const List<int> _codeLengthExtraBits = [2, 3, 7];

  /// Base repeat counts for symbols 16 through 18.
  static const List<int> _codeLengthRepeatOffsets = [3, 3, 11];

  /// Alphabet sizes for the five Huffman trees in a meta-code.
  static const List<int> _alphabetSize = [literalCodeCount + lengthCodeCount, literalCodeCount, literalCodeCount, literalCodeCount, distanceCodeCount];

  /// Signature byte at the start of a VP8L payload.
  static const int vp8lMagicByte = 0x2f;

  /// Supported VP8L bitstream version.
  static const int vp8lVersion = 0;

  /// Position immediately after the last decoded pixel.
  int _lastPixel = 0;

  /// Position immediately after the last emitted row.
  int _lastRow = 0;

  /// Number of entries in the optional color cache.
  int _colorCacheSize = 0;

  /// Optional hashed cache of recently decoded colors.
  _Vp8LosslessColorCache? _colorCache;

  /// Mask selecting a Huffman meta-code tile.
  int _huffmanMask = 0;

  /// Tile-size exponent used by the Huffman meta-image.
  int _huffmanSubsampleBits = 0;

  /// Width of the Huffman meta-image.
  int _huffmanWidth = 0;

  /// Optional image that selects a Huffman tree group per tile.
  Uint32List? _huffmanImage;

  /// Number of Huffman tree groups referenced by the image.
  int _huffmanTreeGroupCount = 0;

  /// Huffman tree groups indexed by the meta-image.
  List<_WebPHuffmanTreeGroup> _huffmanTreeGroups = [];

  /// Inverse transforms in their encoded order.
  final List<_Vp8LosslessTransform> _transforms = [];

  /// Bit mask of transform types already encountered.
  int _transformsSeen = 0;

  /// Rolling buffer of decoded packed pixels.
  Uint32List? _pixels;

  /// Byte view of [_pixels] used by the optimized alpha path.
  late Uint8List _pixels8;

  /// Offset of the first row currently held by [_pixels].
  int? _argbCache;

  /// Destination alpha plane when decoding an alpha-only stream.
  Uint8List? _opaque;

  /// Output width used by alpha-only decoding.
  int? _ioWidth;

  /// Packed opaque black used by predictor mode zero.
  static const int opaqueBlack = 0xff000000;

  /// Maximum color-cache size exponent allowed by VP8L.
  static const int maximumCacheBits = 11;

  /// Number of Huffman trees contained by one meta-code.
  static const int huffmanTreeCount = 5;

  /// Default bit length used by the explicit Huffman representation.
  static const int defaultCodeLength = 8;

  /// Maximum Huffman code length permitted by VP8L.
  static const int maximumCodeLength = 15;

  /// Number of literal color symbols.
  static const int literalCodeCount = 256;

  /// Number of backward-reference length symbols.
  static const int lengthCodeCount = 24;

  /// Number of backward-reference distance symbols.
  static const int distanceCodeCount = 40;

  /// Encoded VP8L bytes.
  final _WebPBuffer input;

  /// Bit reader positioned within [input].
  final _Vp8LosslessBitReader bitReader;

  /// Dimensions and format information shared with the container decoder.
  final _WebPDecodingInfo information;

  /// Destination RGBA image for a full pixel decode.
  Image? image;

  /// Creates a VP8L decoder over [input].
  _Vp8LosslessDecoder({
    required this.input,
    required this.information,
  }) : bitReader = _Vp8LosslessBitReader(input: input);

  /// Reads and validates the VP8L signature, dimensions, alpha flag, and version.
  bool _decodeHeader() {
    final int signature = bitReader.readBits(8);
    if (signature != vp8lMagicByte) {
      return false;
    }

    information
      ..format = _WebPFormat.lossless
      ..width = bitReader.readBits(14) + 1
      ..height = bitReader.readBits(14) + 1
      ..hasAlpha = bitReader.readBits(1) != 0;
    final int version = bitReader.readBits(3);

    if (version != vp8lVersion) {
      return false;
    }

    return true;
  }

  /// Decodes the complete VP8L stream into straight RGBA pixels.
  Image? decode() {
    _lastPixel = 0;

    if (!_decodeHeader()) {
      return null;
    }

    _decodeImageStream(information.width, information.height, true);

    _allocatePixelBuffer();

    image = Image(width: information.width, height: information.height);

    if (!_decodeImageData(_pixels!, information.width, information.height, information.height, _processRows)) {
      return null;
    }

    return image;
  }

  /// Allocates the rolling packed-pixel buffer used by a full decode.
  bool _allocatePixelBuffer() {
    final int numPixels = information.width * information.height;
    // Scratch buffer corresponding to top-prediction row for transforming the
    // first row in the row-blocks. Not needed for paletted alpha.
    final int cacheTopPixels = information.width;
    // Scratch buffer for temporary BGRA storage. Not needed for paletted alpha.
    final int cachePixels = information.width * _pixelCacheRowCount;
    final int totalNumPixels = numPixels + cacheTopPixels + cachePixels;

    final pixels32 = Uint32List(totalNumPixels);
    _pixels = pixels32;
    _pixels8 = Uint8List.view(pixels32.buffer);
    _argbCache = numPixels + cacheTopPixels;

    return true;
  }

  /// Allocates the compact byte buffer used by an alpha-only decode.
  bool _allocateAlphaBuffer() {
    final int totalNumPixels = information.width * information.height;
    _argbCache = 0;
    // pad the byteBuffer to a multiple of 4
    final int n = totalNumPixels + (4 - (totalNumPixels % 4));
    _pixels8 = Uint8List(n);
    _pixels = Uint32List.view(_pixels8.buffer);
    return true;
  }

  /// Reads one inverse transform and updates the effective [transformSize].
  bool _readTransform(List<int> transformSize) {
    var ok = true;

    final int type = bitReader.readBits(2);

    // Each transform type can only be present once in the stream.
    if ((_transformsSeen & (1 << type)) != 0) {
      return false;
    }
    _transformsSeen |= 1 << type;

    final transform = _Vp8LosslessTransform();
    _transforms.add(transform);

    transform
      ..type = _Vp8LosslessTransformType.values[type]
      ..width = transformSize[0]
      ..height = transformSize[1];

    switch (transform.type) {
      case _Vp8LosslessTransformType.predictor:
      case _Vp8LosslessTransformType.crossColor:
        transform.bits = bitReader.readBits(3) + 2;
        transform.data = _decodeImageStream(_subsampledSize(transform.width, transform.bits), _subsampledSize(transform.height, transform.bits), false);
        break;
      case _Vp8LosslessTransformType.colorIndexing:
        final int numColors = bitReader.readBits(8) + 1;
        final bits = (numColors > 16)
            ? 0
            : (numColors > 4)
            ? 1
            : (numColors > 2)
            ? 2
            : 3;
        transformSize[0] = _subsampledSize(transform.width, bits);
        transform.bits = bits;
        transform.data = _decodeImageStream(numColors, 1, false);
        ok = _expandColorMap(numColors, transform);
        break;
      case _Vp8LosslessTransformType.subtractGreen:
        break;
    }

    return ok;
  }

  /// Reads one possibly recursive VP8L image stream.
  Uint32List? _decodeImageStream(int xsize, int ysize, bool isLevel0) {
    var transformXsize = xsize;
    var transformYsize = ysize;
    var colorCacheBits = 0;

    // Read the transforms (may recurse).
    if (isLevel0) {
      while (bitReader.readBits(1) != 0) {
        final sizes = [transformXsize, transformYsize];
        if (!_readTransform(sizes)) {
          throw const ImageCodecException('Invalid Transform');
        }
        transformXsize = sizes[0];
        transformYsize = sizes[1];
      }
    }

    // Color cache
    if (bitReader.readBits(1) != 0) {
      colorCacheBits = bitReader.readBits(4);
      final bool ok = colorCacheBits >= 1 && colorCacheBits <= maximumCacheBits;
      if (!ok) {
        throw const ImageCodecException('Invalid Color Cache');
      }
    }

    // Read the Huffman codes (may recurse).
    if (!_readHuffmanCodes(transformXsize, transformYsize, colorCacheBits, isLevel0)) {
      throw const ImageCodecException('Invalid Huffman Codes');
    }

    // Finish setting up the color-cache
    if (colorCacheBits > 0) {
      _colorCacheSize = 1 << colorCacheBits;
      _colorCache = _Vp8LosslessColorCache(hashBits: colorCacheBits);
    } else {
      _colorCacheSize = 0;
    }

    information
      ..width = transformXsize
      ..height = transformYsize;
    final int numBits = _huffmanSubsampleBits;
    _huffmanWidth = _subsampledSize(transformXsize, numBits);
    _huffmanMask = (numBits == 0) ? ~0 : (1 << numBits) - 1;

    if (isLevel0) {
      // Reset for future DECODE_DATA_FUNC() calls.
      _lastPixel = 0;
      return null;
    }

    final int totalSize = transformXsize * transformYsize;
    final data = Uint32List(totalSize);

    // Use the Huffman trees to decode the LZ77 encoded data.
    if (!_decodeImageData(data, transformXsize, transformYsize, transformYsize, null)) {
      throw const ImageCodecException('Failed to decode image data.');
    }

    // Reset for future DECODE_DATA_FUNC() calls.
    _lastPixel = 0;

    return data;
  }

  /// Expands Huffman symbols and backward references through [lastRow].
  bool _decodeImageData(Uint32List data, int width, int height, int lastRow, void Function(int)? processFunc) {
    int row = _lastPixel ~/ width;
    int col = _lastPixel % width;

    _WebPHuffmanTreeGroup htreeGroup = _huffmanTreeGroupAt(col, row);

    int src = _lastPixel;
    var lastCached = src;
    final int srcEnd = width * height; // End of data
    final int srcLast = width * lastRow; // Last pixel to decode

    const int lenCodeLimit = literalCodeCount + lengthCodeCount;
    final int colorCacheLimit = lenCodeLimit + _colorCacheSize;

    final _Vp8LosslessColorCache? colorCache = (_colorCacheSize > 0) ? _colorCache : null;
    final int mask = _huffmanMask;

    while (src < srcLast) {
      // Only update when changing tile. Note we could use this test:
      // if "((((prev_col ^ col) | prev_row ^ row)) > mask)" -> tile changed
      // but that's actually slower and needs storing the previous col/row.
      if ((col & mask) == 0) {
        htreeGroup = _huffmanTreeGroupAt(col, row);
      }

      bitReader.fillBitWindow();
      final int code = htreeGroup.trees[_green].readSymbol(bitReader);

      if (code < literalCodeCount) {
        // Literal
        final int red = htreeGroup.trees[_red].readSymbol(bitReader);
        final green = code;
        bitReader.fillBitWindow();
        final int blue = htreeGroup.trees[_blue].readSymbol(bitReader);
        final int alpha = htreeGroup.trees[_alpha].readSymbol(bitReader);

        final int c = _rgbaToUint32(blue, green, red, alpha);
        data[src] = c;

        ++src;
        ++col;

        if (col >= width) {
          col = 0;
          ++row;
          if ((row % _pixelCacheRowCount == 0) && (processFunc != null)) {
            processFunc(row);
          }

          if (colorCache != null) {
            while (lastCached < src) {
              colorCache.insert(data[lastCached]);
              lastCached++;
            }
          }
        }
      } else if (code < lenCodeLimit) {
        // Backward reference
        final int lengthSym = code - literalCodeCount;
        final int length = _getCopyLength(lengthSym);
        final int distSymbol = htreeGroup.trees[_dist].readSymbol(bitReader);

        bitReader.fillBitWindow();
        final int distCode = _getCopyDistance(distSymbol);
        final int dist = _planeCodeToDistance(width, distCode);

        if (src < dist || srcEnd - src < length) {
          throw const ImageCodecException('The VP8L stream contains an invalid backward reference');
        }
        final int dst = src - dist;
        for (var i = 0; i < length; ++i) {
          data[src + i] = data[dst + i];
        }
        src += length;
        col += length;
        while (col >= width) {
          col -= width;
          ++row;
          if ((row % _pixelCacheRowCount == 0) && (processFunc != null)) {
            processFunc(row);
          }
        }
        if (src < srcLast) {
          if ((col & mask) != 0) {
            htreeGroup = _huffmanTreeGroupAt(col, row);
          }
          if (colorCache != null) {
            while (lastCached < src) {
              colorCache.insert(data[lastCached]);
              lastCached++;
            }
          }
        }
      } else if (code < colorCacheLimit) {
        // Color cache
        final int key = code - lenCodeLimit;

        while (lastCached < src) {
          colorCache!.insert(data[lastCached]);
          lastCached++;
        }

        data[src] = colorCache!.lookup(key);

        ++src;
        ++col;

        if (col >= width) {
          col = 0;
          ++row;
          if ((row % _pixelCacheRowCount == 0) && (processFunc != null)) {
            processFunc(row);
          }

          while (lastCached < src) {
            colorCache.insert(data[lastCached]);
            lastCached++;
          }
        }
      } else {
        throw const ImageCodecException('The VP8L stream contains an invalid entropy symbol');
      }
    }

    // Process the remaining rows corresponding to last row-block.
    if (processFunc != null) {
      processFunc(row);
    }

    _lastPixel = src;

    return true;
  }

  // Row-processing for the special case when alpha data contains only one
  // transform (color indexing), and trivial non-green literals.
  /// Whether every Huffman tree permits compact alpha-only decoding.
  bool _canUseAlphaBuffer() {
    if (_colorCacheSize > 0) {
      return false;
    }
    // When the Huffman tree contains only one symbol, we can skip the
    // call to ReadSymbol() for red/blue/alpha channels.
    for (var i = 0; i < _huffmanTreeGroupCount; ++i) {
      final List<_WebPHuffmanTree> trees = _huffmanTreeGroups[i].trees;
      if (trees[_red].hasBranches) {
        return false;
      }
      if (trees[_blue].hasBranches) {
        return false;
      }
      if (trees[_alpha].hasBranches) {
        return false;
      }
    }
    return true;
  }

  // Special row-processing that only stores the alpha data.
  /// Extracts newly decoded alpha bytes from packed pixels through [row].
  void _extractAlphaRows(int row) {
    final int numRows = row - _lastRow;
    if (numRows <= 0) {
      return; // Nothing to be done.
    }

    _applyInverseTransforms(numRows, information.width * _lastRow);

    // Extract alpha (which is stored in the green plane).
    final int width = information.width; // the final width (!= dec->width_)
    final int cachePixs = width * numRows;

    final int di = width * _lastRow;
    final src = _WebPBuffer(data: _pixels!, offset: _argbCache!);

    for (var i = 0; i < cachePixs; ++i) {
      _opaque![di + i] = (src[i] >> 8) & 0xff;
    }

    _lastRow = row;
  }

  /// Decodes an optimized alpha-only stream through [lastRow].
  bool _decodeAlphaData(int width, int height, int lastRow) {
    int row = _lastPixel ~/ width;
    int col = _lastPixel % width;

    _WebPHuffmanTreeGroup htreeGroup = _huffmanTreeGroupAt(col, row);
    int pos = _lastPixel; // current position
    final int end = width * height; // End of data
    final int last = width * lastRow; // Last pixel to decode
    const int lenCodeLimit = literalCodeCount + lengthCodeCount;
    final int mask = _huffmanMask;

    while (pos < last) {
      // Only update when changing tile.
      if ((col & mask) == 0) {
        htreeGroup = _huffmanTreeGroupAt(col, row);
      }

      bitReader.fillBitWindow();

      final int code = htreeGroup.trees[_green].readSymbol(bitReader);
      if (code < literalCodeCount) {
        // Literal
        _pixels8[pos] = code;
        ++pos;
        ++col;
        if (col >= width) {
          col = 0;
          ++row;
          if (row % _pixelCacheRowCount == 0) {
            _extractPalettedAlphaRows(row);
          }
        }
      } else if (code < lenCodeLimit) {
        // Backward reference
        final int lengthSym = code - literalCodeCount;
        final int length = _getCopyLength(lengthSym);
        final int distSymbol = htreeGroup.trees[_dist].readSymbol(bitReader);

        bitReader.fillBitWindow();

        final int distCode = _getCopyDistance(distSymbol);
        final int dist = _planeCodeToDistance(width, distCode);

        if (pos < dist || end - pos < length) {
          throw const ImageCodecException('The VP8L alpha stream contains an invalid backward reference');
        }
        for (var i = 0; i < length; ++i) {
          _pixels8[pos + i] = _pixels8[pos + i - dist];
        }

        pos += length;
        col += length;

        while (col >= width) {
          col -= width;
          ++row;
          if (row % _pixelCacheRowCount == 0) {
            _extractPalettedAlphaRows(row);
          }
        }

        if (pos < last && (col & mask) != 0) {
          htreeGroup = _huffmanTreeGroupAt(col, row);
        }
      } else {
        throw const ImageCodecException('The VP8L alpha stream contains an invalid entropy symbol');
      }
    }

    // Process the remaining rows corresponding to last row-block.
    _extractPalettedAlphaRows(row);

    _lastPixel = pos;

    return true;
  }

  /// Expands palette indexes into output alpha rows through [row].
  void _extractPalettedAlphaRows(int row) {
    final int numRows = row - _lastRow;
    final pIn = _WebPBuffer(data: _pixels8, offset: information.width * _lastRow);
    if (numRows > 0) {
      _applyInverseTransformsAlpha(numRows, pIn);
    }
    _lastRow = row;
  }

  // Special method for paletted alpha data.
  /// Applies the palette transform to [numRows] alpha rows.
  void _applyInverseTransformsAlpha(int numRows, _WebPBuffer rows) {
    final int startRow = _lastRow;
    final int endRow = startRow + numRows;
    final rowsOut = _WebPBuffer(data: _opaque!, offset: _ioWidth! * startRow);
    _transforms[0].colorIndexInverseTransformAlpha(startRow, endRow, rows, rowsOut);
  }

  // Processes (transforms, scales & color-converts) the rows decoded after the
  // last call.
  //static int __count = 0;
  /// Applies transforms and emits reconstructed pixels through [row].
  void _processRows(int row) {
    final int rows = information.width * _lastRow; // offset into _pixels
    final int numRows = row - _lastRow;

    if (numRows <= 0) {
      return; // Nothing to be done.
    }

    _applyInverseTransforms(numRows, rows);

    //int count = 0;
    //int di = rows;
    int pixelIndex = _argbCache!;
    int destinationY = _lastRow;
    for (int y = 0; y < numRows; ++y, ++destinationY) {
      for (var x = 0; x < information.width; ++x, ++pixelIndex) {
        final int c = _pixels![pixelIndex];

        final int r = _uint32ToRed(c);
        final int g = _uint32ToGreen(c);
        final int b = _uint32ToBlue(c);
        final int a = _uint32ToAlpha(c);
        // rearrange the ARGB information color to RGBA image color.
        image!.setPixelRgba(x, destinationY, b, g, r, a);
      }
    }

    _lastRow = row;
  }

  /// Applies every encoded inverse transform to [numRows] pending rows.
  void _applyInverseTransforms(int numRows, int rows) {
    int n = _transforms.length;
    final int cachePixs = information.width * numRows;
    final int startRow = _lastRow;
    final int endRow = startRow + numRows;
    var rowsIn = rows;
    final int rowsOut = _argbCache!;

    // Inverse transforms.
    _pixels!.setRange(rowsOut, rowsOut + cachePixs, _pixels!, rowsIn);

    while (n-- > 0) {
      _transforms[n].inverseTransform(startRow, endRow, _pixels!, rowsIn, _pixels!, rowsOut);
      rowsIn = rowsOut;
    }
  }

  /// Reads the optional Huffman meta-image and all referenced tree groups.
  bool _readHuffmanCodes(int xSize, int ySize, int colorCacheBits, bool allowRecursion) {
    Uint32List? huffmanImage;
    var numHtreeGroups = 1;

    if (allowRecursion && bitReader.readBits(1) != 0) {
      // use meta Huffman codes.
      final int huffmanPrecision = bitReader.readBits(3) + 2;
      final int huffmanXsize = _subsampledSize(xSize, huffmanPrecision);
      final int huffmanYsize = _subsampledSize(ySize, huffmanPrecision);
      final int huffmanPixs = huffmanXsize * huffmanYsize;

      huffmanImage = _decodeImageStream(huffmanXsize, huffmanYsize, false);

      _huffmanSubsampleBits = huffmanPrecision;

      for (var i = 0; i < huffmanPixs; ++i) {
        // The huffman data is stored in red and green bytes.
        final int group = (huffmanImage![i] >> 8) & 0xffff;
        huffmanImage[i] = group;
        if (group >= numHtreeGroups) {
          numHtreeGroups = group + 1;
        }
      }
    }

    assert(numHtreeGroups <= 0x10000, 'WebP defines at most 65536 Huffman groups');

    final htreeGroups = List<_WebPHuffmanTreeGroup>.generate(numHtreeGroups, (_) => _WebPHuffmanTreeGroup(), growable: false);
    for (var i = 0; i < numHtreeGroups; ++i) {
      for (var j = 0; j < huffmanTreeCount; ++j) {
        int alphabetSize = _alphabetSize[j];
        if (j == 0 && colorCacheBits > 0) {
          alphabetSize += 1 << colorCacheBits;
        }

        if (!_readHuffmanCode(alphabetSize, htreeGroups[i].trees[j])) {
          return false;
        }
      }
    }

    // All OK. Finalize pointers and return.
    _huffmanImage = huffmanImage;
    _huffmanTreeGroupCount = numHtreeGroups;
    _huffmanTreeGroups = htreeGroups;

    return true;
  }

  /// Reads one simple or canonical Huffman tree for [alphabetSize] symbols.
  bool _readHuffmanCode(int alphabetSize, _WebPHuffmanTree tree) {
    var ok = false;
    final int simpleCode = bitReader.readBits(1);

    // Read symbols, codes & code lengths directly.
    if (simpleCode != 0) {
      final symbols = [0, 0];
      final codes = [0, 0];
      final codeLengths = [0, 0];

      final int numSymbols = bitReader.readBits(1) + 1;
      final int firstSymbolLenCode = bitReader.readBits(1);

      // The first code is either 1 bit or 8 bit code.
      symbols[0] = bitReader.readBits((firstSymbolLenCode == 0) ? 1 : 8);
      codes[0] = 0;
      codeLengths[0] = numSymbols - 1;

      // The second code (if present), is always 8 bit long.
      if (numSymbols == 2) {
        symbols[1] = bitReader.readBits(8);
        codes[1] = 1;
        codeLengths[1] = numSymbols - 1;
      }

      ok = tree.buildFromCodes(codeLengths, codes, symbols, alphabetSize, numSymbols);
    } else {
      // Decode Huffman-coded code lengths.
      final codeLengthCodeLengths = Int32List(_numCodeLengthCodes);

      final int numCodes = bitReader.readBits(4) + 4;
      if (numCodes > _numCodeLengthCodes) {
        return false;
      }

      final codeLengths = Int32List(alphabetSize);

      for (var i = 0; i < numCodes; ++i) {
        codeLengthCodeLengths[_codeLengthCodeOrder[i]] = bitReader.readBits(3);
      }

      ok = _readHuffmanCodeLengths(codeLengthCodeLengths, alphabetSize, codeLengths);

      if (ok) {
        ok = tree.buildFromLengths(codeLengths, alphabetSize);
      }
    }

    return ok;
  }

  /// Expands repeat-coded Huffman lengths into [codeLengths].
  bool _readHuffmanCodeLengths(List<int> codeLengthCodeLengths, int numSymbols, List<int> codeLengths) {
    //bool ok = false;
    int symbol;
    int maxSymbol;
    int prevCodeLen = defaultCodeLength;
    final tree = _WebPHuffmanTree();

    if (!tree.buildFromLengths(codeLengthCodeLengths, _numCodeLengthCodes)) {
      return false;
    }

    if (bitReader.readBits(1) != 0) {
      // use length
      final int lengthNBits = 2 + 2 * bitReader.readBits(3);
      maxSymbol = 2 + bitReader.readBits(lengthNBits);
      if (maxSymbol > numSymbols) {
        return false;
      }
    } else {
      maxSymbol = numSymbols;
    }

    symbol = 0;
    while (symbol < numSymbols) {
      int codeLen;
      if (maxSymbol-- == 0) {
        break;
      }

      bitReader.fillBitWindow();

      codeLen = tree.readSymbol(bitReader);

      if (codeLen < _codeLengthLiterals) {
        codeLengths[symbol++] = codeLen;
        if (codeLen != 0) {
          prevCodeLen = codeLen;
        }
      } else {
        final usePrev = codeLen == _codeLengthRepeatCode;
        final int slot = codeLen - _codeLengthLiterals;
        final int extraBits = _codeLengthExtraBits[slot];
        final int repeatOffset = _codeLengthRepeatOffsets[slot];
        int repeat = bitReader.readBits(extraBits) + repeatOffset;

        if (symbol + repeat > numSymbols) {
          return false;
        } else {
          final length = usePrev ? prevCodeLen : 0;
          while (repeat-- > 0) {
            codeLengths[symbol++] = length;
          }
        }
      }
    }

    return true;
  }

  /// Decodes the backward-reference value represented by [distanceSymbol].
  int _getCopyDistance(int distanceSymbol) {
    if (distanceSymbol < 4) {
      return distanceSymbol + 1;
    }
    final int extraBits = (distanceSymbol - 2) >> 1;
    final int offset = (2 + (distanceSymbol & 1)) << extraBits;
    return offset + bitReader.readBits(extraBits) + 1;
  }

  /// Decodes the backward-reference length represented by [lengthSymbol].
  int _getCopyLength(int lengthSymbol) => _getCopyDistance(lengthSymbol);

  /// Converts a compact two-dimensional [planeCode] to a linear distance.
  int _planeCodeToDistance(int xsize, int planeCode) {
    if (planeCode > _codeToPlaneCodes) {
      return planeCode - _codeToPlaneCodes;
    } else {
      final int distCode = _codeToPlane[planeCode - 1];
      final int yoffset = distCode >> 4;
      final int xoffset = 8 - (distCode & 0xf);
      final int dist = yoffset * xsize + xoffset;
      // dist<1 can happen if xsize is very small
      return (dist >= 1) ? dist : 1;
    }
  }

  // Computes sampled size of 'size' when sampling using 'sampling bits'.
  /// Returns the ceiling of [size] divided by the sampling block size.
  static int _subsampledSize(int size, int samplingBits) => (size + (1 << samplingBits) - 1) >> samplingBits;

  // For security reason, we need to remap the color map to span
  // the total possible bundled values, and not just the num_colors.
  /// Reconstructs [numColors] cumulative entries in a palette transform.
  bool _expandColorMap(int numColors, _Vp8LosslessTransform transform) {
    final int finalNumColors = 1 << (8 >> transform.bits);
    final newColorMap = Uint32List(finalNumColors);
    final data = Uint8List.view(transform.data!.buffer);
    final newData = Uint8List.view(newColorMap.buffer);

    newColorMap[0] = transform.data![0];

    int len = 4 * numColors;

    int i;
    for (i = 4; i < len; ++i) {
      // Equivalent to AddPixelEq(), on a byte-basis.
      newData[i] = (data[i] + newData[i - 4]) & 0xff;
    }

    for (len = 4 * finalNumColors; i < len; ++i) {
      newData[i] = 0;
    }

    transform.data = newColorMap;

    return true;
  }

  /// Returns the meta-image value selecting the tile containing ([x], [y]).
  int _getMetaIndex(Uint32List? image, int xsize, int bits, int x, int y) {
    if (bits == 0) {
      return 0;
    }
    return image![xsize * (y >> bits) + (x >> bits)];
  }

  /// Returns the Huffman tree group selected for pixel ([x], [y]).
  _WebPHuffmanTreeGroup _huffmanTreeGroupAt(int x, int y) {
    final int metaIndex = _getMetaIndex(_huffmanImage, _huffmanWidth, _huffmanSubsampleBits, x, y);
    return _huffmanTreeGroups[metaIndex];
  }
}
