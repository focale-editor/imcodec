part of '../webp.dart';

/// Decodes canonical Huffman symbols from a VP8L bitstream.
final class _WebPHuffmanTree {
  /// Number of bits handled by the direct lookup table.
  static const int _lookupBits = 7;

  /// Number of entries in each direct lookup table.
  static const int _lookupSize = 1 << _lookupBits;

  /// Reversed values for every four-bit input.
  static const List<int> _reversedBits = [0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe, 0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf];

  /// Bit lengths for codes handled by the direct lookup table.
  final Uint8List _lookupBitLengths = Uint8List(_lookupSize);

  /// Symbols handled by the direct lookup table.
  final Int16List _lookupSymbols = Int16List(_lookupSize);

  /// Tree offsets for codes longer than [_lookupBits].
  final Int16List _lookupJumps = Int16List(_lookupSize);

  /// Flattened pairs of symbol values and child offsets.
  late Int32List _nodes;

  /// Maximum number of nodes allowed by the current alphabet.
  int _maximumNodeCount = 0;

  /// Number of nodes currently occupied.
  int _nodeCount = 0;

  /// Creates an empty Huffman tree ready to be built.
  _WebPHuffmanTree();

  /// Builds a canonical tree from one code length per symbol.
  bool buildFromLengths(List<int> codeLengths, int symbolCount) {
    int populatedSymbolCount = 0;
    int rootSymbol = 0;
    for (int symbol = 0; symbol < symbolCount; symbol++) {
      if (codeLengths[symbol] > 0) {
        populatedSymbolCount++;
        rootSymbol = symbol;
      }
    }
    if (!_initialize(populatedSymbolCount)) {
      return false;
    }
    if (populatedSymbolCount == 1) {
      return rootSymbol >= 0 && rootSymbol < symbolCount && _addSymbol(rootSymbol, 0, 0);
    }

    final Int32List codes = Int32List(symbolCount);
    if (!_codeLengthsToCodes(codeLengths, symbolCount, codes)) {
      return false;
    }
    for (int symbol = 0; symbol < symbolCount; symbol++) {
      if (codeLengths[symbol] > 0 && !_addSymbol(symbol, codes[symbol], codeLengths[symbol])) {
        return false;
      }
    }
    return _isFull;
  }

  /// Builds a tree from explicit [codes], lengths, and symbol values.
  bool buildFromCodes(List<int> codeLengths, List<int> codes, List<int> symbols, int maximumSymbol, int symbolCount) {
    if (!_initialize(symbolCount)) {
      return false;
    }
    for (int index = 0; index < symbolCount; index++) {
      if (codes[index] == -1) {
        continue;
      }
      if (symbols[index] < 0 || symbols[index] >= maximumSymbol) {
        return _isFull;
      }
      if (!_addSymbol(symbols[index], codes[index], codeLengths[index])) {
        return _isFull;
      }
    }
    return _isFull;
  }

  /// Reads the next symbol after the caller has filled the bit window.
  int readSymbol(_Vp8LosslessBitReader bitReader) {
    int node = 0;
    int bits = bitReader.prefetchBits();
    int consumedBitCount = 0;
    final int lookupIndex = bits & (_lookupSize - 1);
    final int lookupBitLength = _lookupBitLengths[lookupIndex];
    if (lookupBitLength <= _lookupBits) {
      bitReader.advanceBits(lookupBitLength);
      return _lookupSymbols[lookupIndex];
    }

    node += _lookupJumps[lookupIndex];
    consumedBitCount += _lookupBits;
    bits >>= _lookupBits;
    do {
      node = _nextNode(node, bits & 1);
      bits >>= 1;
      consumedBitCount++;
    } while (_isBranch(node));
    bitReader.advanceBits(consumedBitCount);
    return _symbol(node);
  }

  /// Whether the tree contains more than its root node.
  bool get hasBranches => _nodeCount > 1;

  /// Allocates a tree capable of storing [leafCount] leaves.
  bool _initialize(int leafCount) {
    if (leafCount == 0) {
      return false;
    }
    _maximumNodeCount = (leafCount << 1) - 1;
    _nodes = Int32List(_maximumNodeCount << 1);
    _nodes[1] = -1;
    _nodeCount = 1;
    _lookupBitLengths.fillRange(0, _lookupBitLengths.length, 255);
    return true;
  }

  /// Inserts one [symbol] at the supplied canonical [code].
  bool _addSymbol(int symbol, int code, int codeLength) {
    int lookupSteps = _lookupBits;
    int remainingCodeLength = codeLength;
    final int baseCode;
    int node = 0;
    if (codeLength <= _lookupBits) {
      baseCode = _reverseShortCode(code, codeLength);
      for (int index = 0; index < 1 << (_lookupBits - codeLength); index++) {
        final int lookupIndex = baseCode | (index << codeLength);
        _lookupSymbols[lookupIndex] = symbol;
        _lookupBitLengths[lookupIndex] = codeLength;
      }
    } else {
      baseCode = _reverseShortCode(code >> (codeLength - _lookupBits), _lookupBits);
    }

    while (remainingCodeLength-- > 0) {
      if (node >= _maximumNodeCount) {
        return false;
      }
      if (_isEmpty(node)) {
        if (_isFull) {
          return false;
        }
        _assignChildren(node);
      } else if (!_isBranch(node)) {
        return false;
      }
      node += _childrenOffset(node) + ((code >> remainingCodeLength) & 1);
      if (--lookupSteps == 0) {
        _lookupJumps[baseCode] = node;
      }
    }

    if (_isEmpty(node)) {
      _setChildrenOffset(node, 0);
    } else if (_isBranch(node)) {
      return false;
    }
    _setSymbol(node, symbol);
    return true;
  }

  /// Converts canonical code lengths to their integer codes.
  bool _codeLengthsToCodes(List<int> codeLengths, int symbolCount, Int32List codes) {
    final Int32List lengthHistogram = Int32List(_Vp8LosslessDecoder.maximumCodeLength + 1);
    final Int32List nextCodes = Int32List(_Vp8LosslessDecoder.maximumCodeLength + 1);
    int maximumCodeLength = 0;
    for (int symbol = 0; symbol < symbolCount; symbol++) {
      maximumCodeLength = math.max(maximumCodeLength, codeLengths[symbol]);
    }
    if (maximumCodeLength > _Vp8LosslessDecoder.maximumCodeLength) {
      return false;
    }
    for (int symbol = 0; symbol < symbolCount; symbol++) {
      lengthHistogram[codeLengths[symbol]]++;
    }
    lengthHistogram[0] = 0;

    int currentCode = 0;
    nextCodes[0] = -1;
    for (int codeLength = 1; codeLength <= maximumCodeLength; codeLength++) {
      currentCode = (currentCode + lengthHistogram[codeLength - 1]) << 1;
      nextCodes[codeLength] = currentCode;
    }
    for (int symbol = 0; symbol < symbolCount; symbol++) {
      final int codeLength = codeLengths[symbol];
      codes[symbol] = codeLength == 0 ? -1 : nextCodes[codeLength]++;
    }
    return true;
  }

  /// Returns the bit-reversed form of a code no longer than eight bits.
  int _reverseShortCode(int bits, int bitCount) {
    final int reversed = (_reversedBits[bits & 0x0f] << 4) | _reversedBits[bits >> 4];
    return reversed >> (8 - bitCount);
  }

  /// Whether every allocated node is occupied.
  bool get _isFull => _nodeCount == _maximumNodeCount;

  /// Resolves a child node relative to [node].
  int _nextNode(int node, int rightChild) => node + _childrenOffset(node) + rightChild;

  /// Reads the symbol stored by [node].
  int _symbol(int node) => _nodes[node << 1];

  /// Stores [symbol] in [node].
  void _setSymbol(int node, int symbol) => _nodes[node << 1] = symbol;

  /// Reads the relative child offset stored by [node].
  int _childrenOffset(int node) => _nodes[(node << 1) + 1];

  /// Stores a relative [offset] to the first child of [node].
  void _setChildrenOffset(int node, int offset) => _nodes[(node << 1) + 1] = offset;

  /// Whether [node] points to children rather than a symbol.
  bool _isBranch(int node) => _childrenOffset(node) != 0;

  /// Whether [node] has not been initialized.
  bool _isEmpty(int node) => _childrenOffset(node) < 0;

  /// Allocates both children of [node].
  void _assignChildren(int node) {
    final int firstChild = _nodeCount;
    _setChildrenOffset(node, firstChild - node);
    _nodeCount += 2;
    _setChildrenOffset(firstChild, -1);
    _setChildrenOffset(firstChild + 1, -1);
  }
}

/// Groups the five Huffman alphabets used by one VP8L meta-code.
final class _WebPHuffmanTreeGroup {
  /// Trees for green, red, blue, alpha, and distance symbols.
  final List<_WebPHuffmanTree> trees;

  /// Creates one empty tree for every VP8L alphabet.
  _WebPHuffmanTreeGroup() : trees = List<_WebPHuffmanTree>.generate(_Vp8LosslessDecoder.huffmanTreeCount, (_) => _WebPHuffmanTree(), growable: false);

  /// Returns the tree at [index].
  _WebPHuffmanTree operator [](int index) => trees[index];
}
