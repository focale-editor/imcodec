part of '../jpeg.dart';

/// Decodes Huffman-coded coefficients for one JPEG scan.
final class _JpegScanDecoder {
  /// Reader positioned at the entropy-coded scan.
  final _JpegInput input;

  /// Frame receiving decoded coefficients.
  final _JpegFrame frame;

  /// Components included in this scan.
  final List<_JpegComponent> components;

  /// Configured restart interval, or zero when none is present.
  final int? resetInterval;

  /// First coefficient included by progressive spectral selection.
  final int spectralStart;

  /// Last coefficient included by progressive spectral selection.
  final int spectralEnd;

  /// Previous progressive approximation bit position.
  final int successivePrevious;

  /// Current progressive approximation bit position.
  final int successive;

  /// Mask applied to the entropy bit register.
  static const int _bitDataMask = 0xffffffffff;

  /// Buffered entropy bits, most significant bit first.
  int _bitData = 0;

  /// Number of unread bits in [_bitData].
  int _bitCount = 0;

  /// Progressive end-of-band run remaining.
  int _endOfBandRun = 0;

  /// State of progressive alternating-current refinement.
  int _successiveState = 0;

  /// Coefficient value pending during progressive refinement.
  late int _successiveNextValue;

  /// Creates a decoder for one scan header and its entropy payload.
  _JpegScanDecoder({
    required this.input,
    required this.frame,
    required this.components,
    required this.resetInterval,
    required this.spectralStart,
    required this.spectralEnd,
    required this.successivePrevious,
    required this.successive,
  });

  /// Decodes all minimum coded units covered by the scan.
  void decode() {
    final void Function(_JpegComponent, Int32List) decodeBlock = frame.progressive
        ? spectralStart == 0
              ? successivePrevious == 0
                    ? _decodeDirectCurrentFirst
                    : _decodeDirectCurrentSuccessive
              : successivePrevious == 0
              ? _decodeAlternatingCurrentFirst
              : _decodeAlternatingCurrentSuccessive
        : _decodeBaseline;
    final int expectedUnits = components.length == 1 ? components.first.blocksPerLine * components.first.blocksPerColumn : frame.minimumCodedUnitsPerLine * frame.minimumCodedUnitsPerColumn;
    final int interval = resetInterval == null || resetInterval == 0 ? expectedUnits : resetInterval!;
    int unit = 0;
    int expectedRestartMarker = JpegMarker.restart0;

    while (unit < expectedUnits) {
      for (final _JpegComponent component in components) {
        component.prediction = 0;
      }
      _endOfBandRun = 0;
      final int intervalEnd = math.min(unit + interval, expectedUnits);
      if (components.length == 1) {
        final _JpegComponent component = components.first;
        while (unit < intervalEnd) {
          _decodeSingleComponentBlock(component, decodeBlock, unit++);
        }
      } else {
        while (unit < intervalEnd) {
          for (final _JpegComponent component in components) {
            for (int row = 0; row < component.verticalSamples; row++) {
              for (int column = 0; column < component.horizontalSamples; column++) {
                _decodeMinimumCodedUnit(component, decodeBlock, unit, row, column);
              }
            }
          }
          unit++;
        }
      }
      _bitCount = 0;
      _bitData = 0;
      _successiveState = 0;
      if (unit < expectedUnits) {
        if (input.length < 2 || input[0] != 0xff || input[1] != expectedRestartMarker) {
          throw const ImageCodecException('JPEG restart marker is missing or out of sequence');
        }
        input.skip(2);
        expectedRestartMarker = expectedRestartMarker == JpegMarker.restart7 ? JpegMarker.restart0 : expectedRestartMarker + 1;
      }
    }
  }

  /// Fills the bit register so that it holds at least [count] bits.
  /// Byte stuffing is unwound here so that the hot decoding paths only see a
  /// continuous bit stream.
  void _fill(int count) {
    while (_bitCount < count) {
      if (input.isEOS) {
        throw const ImageCodecException('JPEG entropy data is truncated');
      }
      final int byte = input.readByte();
      if (byte == 0xff) {
        if (input.isEOS) {
          throw const ImageCodecException('JPEG entropy data ends inside a marker');
        }
        final int stuffed = input.readByte();
        if (stuffed != 0) {
          input.offset -= 2;
          throw const ImageCodecException('JPEG entropy scan ended before all coefficients were decoded');
        }
      }
      _bitData = ((_bitData << 8) | byte) & _bitDataMask;
      _bitCount += 8;
    }
  }

  /// Reads one entropy bit while handling byte stuffing.
  int _readBit() {
    if (_bitCount == 0) {
      _fill(1);
    }
    _bitCount--;
    return (_bitData >>> _bitCount) & 1;
  }

  /// Decodes one Huffman symbol using a direct lookup with canonical fallback.
  int _decodeHuffman(_JpegHuffmanTable table) {
    const int lookupBits = _JpegHuffmanTable.lookupBits;
    if (_bitCount < lookupBits) {
      _fillOrPad(lookupBits);
    }
    final int prefix = (_bitData >>> (_bitCount - lookupBits)) & ((1 << lookupBits) - 1);
    final int entry = table.lookup[prefix];
    if (entry != 0) {
      final int length = entry >>> 8;
      if (length > _bitCount) {
        throw const ImageCodecException('JPEG entropy data is truncated');
      }
      _bitCount -= length;
      return entry & 0xff;
    }

    int code = 0;
    for (int length = 1; length <= 16; length++) {
      code = (code << 1) | _readBit();
      final int maximumCode = table.maximumCodes[length - 1];
      if (maximumCode >= 0 && code <= maximumCode) {
        return table.symbols[table.valueOffsets[length - 1] + code - table.minimumCodes[length - 1]];
      }
    }
    throw const ImageCodecException('JPEG entropy data contains an invalid Huffman code');
  }

  /// Fills the register, tolerating a stream that ends mid-symbol.
  /// The final Huffman code of a scan may be shorter than the lookup window,
  /// so a truncated fill is only an error once the decoder consumes the
  /// missing bits.
  void _fillOrPad(int count) {
    try {
      _fill(count);
    } on ImageCodecException {
      if (_bitCount == 0) {
        rethrow;
      }
      _bitData = (_bitData << (count - _bitCount)) & _bitDataMask;
      _bitCount = count;
    }
  }

  /// Reads an unsigned entropy value of [length] bits.
  int _receive(int length) {
    if (length == 0) {
      return 0;
    }
    if (_bitCount < length) {
      _fill(length);
    }
    _bitCount -= length;
    return (_bitData >>> _bitCount) & ((1 << length) - 1);
  }

  /// Reads a JPEG sign-magnitude coefficient difference.
  int _receiveAndExtend(int length) {
    if (length == 0) {
      return 0;
    }
    final int value = _receive(length);
    return value >= 1 << (length - 1) ? value : value + (-1 << length) + 1;
  }

  /// Decodes one complete baseline coefficient block.
  void _decodeBaseline(_JpegComponent component, Int32List coefficients) {
    final int directCurrentLength = _decodeHuffman(component.huffmanTableDc);
    component.prediction += _receiveAndExtend(directCurrentLength);
    coefficients[0] = component.prediction;
    int coefficient = 1;
    while (coefficient < 64) {
      final int symbol = _decodeHuffman(component.huffmanTableAc);
      final int run = symbol >>> 4;
      final int length = symbol & 0x0f;
      if (length == 0) {
        if (run < 15) {
          return;
        }
        coefficient += 16;
        continue;
      }
      coefficient += run;
      if (coefficient >= 64) {
        throw const ImageCodecException('JPEG alternating-current run exceeds its block');
      }
      coefficients[jpegZigZagToNaturalOrderWithPadding[coefficient++]] = _receiveAndExtend(length);
    }
  }

  /// Decodes the first progressive direct-current approximation.
  void _decodeDirectCurrentFirst(_JpegComponent component, Int32List coefficients) {
    final int length = _decodeHuffman(component.huffmanTableDc);
    component.prediction += _receiveAndExtend(length) << successive;
    coefficients[0] = component.prediction;
  }

  /// Refines a previously decoded progressive direct-current coefficient.
  void _decodeDirectCurrentSuccessive(_JpegComponent component, Int32List coefficients) {
    coefficients[0] |= _readBit() << successive;
  }

  /// Decodes the first progressive alternating-current approximation.
  void _decodeAlternatingCurrentFirst(_JpegComponent component, Int32List coefficients) {
    if (_endOfBandRun > 0) {
      _endOfBandRun--;
      return;
    }
    int coefficient = spectralStart;
    while (coefficient <= spectralEnd) {
      final int symbol = _decodeHuffman(component.huffmanTableAc);
      final int run = symbol >>> 4;
      final int length = symbol & 0x0f;
      if (length == 0) {
        if (run < 15) {
          _endOfBandRun = _receive(run) + (1 << run) - 1;
          return;
        }
        coefficient += 16;
        continue;
      }
      coefficient += run;
      if (coefficient > spectralEnd) {
        throw const ImageCodecException('Progressive JPEG run exceeds its spectral band');
      }
      coefficients[jpegZigZagToNaturalOrderWithPadding[coefficient++]] = _receiveAndExtend(length) << successive;
    }
  }

  /// Refines a progressive alternating-current spectral band.
  void _decodeAlternatingCurrentSuccessive(_JpegComponent component, Int32List coefficients) {
    int coefficient = spectralStart;
    int zeroRun = 0;
    while (coefficient <= spectralEnd) {
      final int naturalIndex = jpegZigZagToNaturalOrderWithPadding[coefficient];
      switch (_successiveState) {
        case 0:
          final int symbol = _decodeHuffman(component.huffmanTableAc);
          final int length = symbol & 0x0f;
          zeroRun = symbol >>> 4;
          if (length == 0) {
            if (zeroRun < 15) {
              _endOfBandRun = _receive(zeroRun) + (1 << zeroRun);
              _successiveState = 4;
            } else {
              zeroRun = 16;
              _successiveState = 1;
            }
          } else {
            if (length != 1) {
              throw const ImageCodecException('Invalid progressive JPEG refinement symbol');
            }
            _successiveNextValue = _receiveAndExtend(length);
            _successiveState = zeroRun == 0 ? 3 : 2;
          }
          continue;
        case 1 || 2:
          if (coefficients[naturalIndex] != 0) {
            _refineCoefficient(coefficients, naturalIndex);
          } else if (--zeroRun == 0) {
            _successiveState = _successiveState == 2 ? 3 : 0;
          }
        case 3:
          if (coefficients[naturalIndex] != 0) {
            _refineCoefficient(coefficients, naturalIndex);
          } else {
            coefficients[naturalIndex] = _successiveNextValue << successive;
            _successiveState = 0;
          }
        case 4:
          if (coefficients[naturalIndex] != 0) {
            _refineCoefficient(coefficients, naturalIndex);
          }
        default:
          throw const ImageCodecException('Invalid progressive JPEG decoder state');
      }
      coefficient++;
    }
    if (_successiveState == 4 && --_endOfBandRun == 0) {
      _successiveState = 0;
    }
  }

  /// Applies one refinement bit without changing an already-set bit.
  void _refineCoefficient(Int32List coefficients, int index) {
    final int bit = _readBit() << successive;
    if (bit != 0 && (coefficients[index].abs() & bit) == 0) {
      coefficients[index] += coefficients[index] > 0 ? bit : -bit;
    }
  }

  /// Resolves one interleaved minimum coded unit to a component block.
  void _decodeMinimumCodedUnit(
    _JpegComponent component,
    void Function(_JpegComponent, Int32List) decodeBlock,
    int unit,
    int row,
    int column,
  ) {
    final int unitRow = unit ~/ frame.minimumCodedUnitsPerLine;
    final int unitColumn = unit % frame.minimumCodedUnitsPerLine;
    final int blockRow = unitRow * component.verticalSamples + row;
    final int blockColumn = unitColumn * component.horizontalSamples + column;
    if (blockRow < component.blocks.length && blockColumn < component.blocks[blockRow].length) {
      decodeBlock(component, component.blocks[blockRow][blockColumn]);
    }
  }

  /// Resolves one non-interleaved unit to a component block.
  void _decodeSingleComponentBlock(
    _JpegComponent component,
    void Function(_JpegComponent, Int32List) decodeBlock,
    int unit,
  ) {
    final int blockRow = unit ~/ component.blocksPerLine;
    final int blockColumn = unit % component.blocksPerLine;
    decodeBlock(component, component.blocks[blockRow][blockColumn]);
  }
}
