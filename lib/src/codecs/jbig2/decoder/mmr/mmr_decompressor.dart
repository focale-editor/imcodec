// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 mmr decoder procedure.
class _Jbig2MmrDecoder {
  /// Stores width.
  int width;

  /// Stores height.
  int height;

  /// Stores data.
  late _Jbig2RunData data;

  /// Stores first level table size.
  static const int firstLevelTableSize = 8;

  /// Stores first level table mask.
  static const int firstLevelTableMask = (1 << firstLevelTableSize) - 1;

  /// Stores second level table size.
  static const int secondLevelTableSize = 5;

  /// Stores second level table mask.
  static const int secondLevelTableMask = (1 << secondLevelTableSize) - 1;

  /// Stores white table.
  static List<_Jbig2MmrCode?>? whiteTable;

  /// Stores black table.
  static List<_Jbig2MmrCode?>? blackTable;

  /// Stores mode table.
  static List<_Jbig2MmrCode?>? modeTable;

  /// Creates the mmr decoder state.
  _Jbig2MmrDecoder({
    required this.width,
    required this.height,
    required _Jbig2ByteReader stream,
  }) {
    data = _Jbig2RunData(stream: stream);
    initTables();
  }

  /// Initializes tables.
  static void initTables() {
    if (whiteTable == null) {
      whiteTable = createLittleEndianTable(_Jbig2MmrConstants.whiteCodes);
      blackTable = createLittleEndianTable(_Jbig2MmrConstants.blackCodes);
      modeTable = createLittleEndianTable(_Jbig2MmrConstants.modeCodes);
    }
  }

  /// Computes uncompress.
  _Jbig2Bitmap uncompress() {
    final _Jbig2Bitmap result = _Jbig2Bitmap(width: width, height: height);

    List<int> currentOffsets = List.filled(_Jbig2Budget.reserve(width + 5, 8), 0);
    List<int> referenceOffsets = List.filled(_Jbig2Budget.reserve(width + 5, 8), 0);
    referenceOffsets[0] = width;
    int refRunLength = 1;

    int count = 0;

    for (int line = 0; line < height; line++) {
      count = uncompress2D(data, referenceOffsets, refRunLength, currentOffsets, width);

      if (count == _Jbig2MmrConstants.endOfFile) {
        break;
      }

      if (count > 0) {
        fillBitmap(result, line, currentOffsets, count);
      }

      // Swap lines
      final List<int> tempOffsets = referenceOffsets;
      referenceOffsets = currentOffsets;
      currentOffsets = tempOffsets;
      refRunLength = count;
    }

    detectAndSkipEOL();

    data.align();

    return result;
  }

  /// Computes detect and skip eol.
  void detectAndSkipEOL() {
    while (true) {
      final _Jbig2MmrCode? code = data.uncompressGetCode(modeTable!);
      if (code != null && code.runLength == _Jbig2MmrConstants.endOfLine) {
        data.offset += code.bitLength;
      } else {
        break;
      }
    }
  }

  /// Fills bitmap.
  void fillBitmap(_Jbig2Bitmap result, int line, List<int> currentOffsets, int count) {
    int x = 0;
    int targetByte = result.getByteIndex(0, line);
    int targetByteValue = 0;
    for (int index = 0; index < count; index++) {
      final int offset = currentOffsets[index];
      int value;

      if ((index & 1) == 0) {
        value = 0;
      } else {
        value = 1;
      }

      while (x < offset) {
        targetByteValue = (targetByteValue << 1) | value;
        x++;

        if ((x & 7) == 0) {
          result.setByte(targetByte++, targetByteValue);
          targetByteValue = 0;
        }
      }
    }

    if ((x & 7) != 0) {
      targetByteValue <<= 8 - (x & 7);
      result.setByte(targetByte, targetByteValue);
    }
  }

  /// Computes uncompress2 d.
  int uncompress2D(_Jbig2RunData runData, List<int> referenceOffsets, int refRunLength, List<int> runOffsets, int width) {
    int referenceBufferOffset = 0;
    int currentBufferOffset = 0;
    int currentLineBitPosition = 0;

    bool whiteRun = true; // Always start with a white run
    _Jbig2MmrCode? code; // Storage var for current code being processed

    referenceOffsets[refRunLength] = referenceOffsets[refRunLength + 1] = width;
    referenceOffsets[refRunLength + 2] = referenceOffsets[refRunLength + 3] = width + 1;

    try {
      decodeLoop:
      while (currentLineBitPosition < width) {
        // Get the mode code
        code = runData.uncompressGetCode(modeTable!);

        if (code == null) {
          runData.offset++;
          break decodeLoop;
        }

        // Add the code length to the bit offset
        runData.offset += code.bitLength;

        switch (code.runLength) {
          case _Jbig2MmrConstants.codeV0:
            currentLineBitPosition = referenceOffsets[referenceBufferOffset];

          case _Jbig2MmrConstants.codeVr1:
            currentLineBitPosition = referenceOffsets[referenceBufferOffset] + 1;

          case _Jbig2MmrConstants.codeVl1:
            currentLineBitPosition = referenceOffsets[referenceBufferOffset] - 1;

          case _Jbig2MmrConstants.codeH:
            for (final int ever = 1; ever > 0;) {
              code = runData.uncompressGetCode(whiteRun ? whiteTable! : blackTable!);

              if (code == null) {
                break decodeLoop;
              }

              runData.offset += code.bitLength;
              if (code.runLength < 64) {
                if (code.runLength < 0) {
                  runOffsets[currentBufferOffset++] = currentLineBitPosition;
                  code = null;
                  break decodeLoop;
                }
                currentLineBitPosition += code.runLength;
                runOffsets[currentBufferOffset++] = currentLineBitPosition;
                break;
              }
              currentLineBitPosition += code.runLength;
            }

            final int firstHalfBitPos = currentLineBitPosition;
            for (final int ever1 = 1; ever1 > 0;) {
              code = runData.uncompressGetCode(!whiteRun ? whiteTable! : blackTable!);
              if (code == null) {
                break decodeLoop;
              }

              runData.offset += code.bitLength;
              if (code.runLength < 64) {
                if (code.runLength < 0) {
                  runOffsets[currentBufferOffset++] = currentLineBitPosition;
                  break decodeLoop;
                }
                currentLineBitPosition += code.runLength;
                // don't generate 0-length run at endOfLine for cases where the line ends in an H-run.
                if (currentLineBitPosition < width || currentLineBitPosition != firstHalfBitPos) {
                  runOffsets[currentBufferOffset++] = currentLineBitPosition;
                }
                break;
              }
              currentLineBitPosition += code.runLength;
            }

            while (currentLineBitPosition < width && referenceOffsets[referenceBufferOffset] <= currentLineBitPosition) {
              referenceBufferOffset += 2;
            }
            continue decodeLoop;

          case _Jbig2MmrConstants.codeP:
            referenceBufferOffset++;
            currentLineBitPosition = referenceOffsets[referenceBufferOffset++];
            continue decodeLoop;

          case _Jbig2MmrConstants.codeVr2:
            currentLineBitPosition = referenceOffsets[referenceBufferOffset] + 2;

          case _Jbig2MmrConstants.codeVl2:
            currentLineBitPosition = referenceOffsets[referenceBufferOffset] - 2;

          case _Jbig2MmrConstants.codeVr3:
            currentLineBitPosition = referenceOffsets[referenceBufferOffset] + 3;

          case _Jbig2MmrConstants.codeVl3:
            currentLineBitPosition = referenceOffsets[referenceBufferOffset] - 3;

          case _Jbig2MmrConstants.endOfLine:
          default:

            // Possibly MMR Decoded
            if (runData.offset == 12 && code.runLength == _Jbig2MmrConstants.endOfLine) {
              runData.offset = 0;
              uncompress1D(runData, referenceOffsets, width);
              runData.offset++;
              uncompress1D(runData, runOffsets, width);
              final int retCode = uncompress1D(runData, referenceOffsets, width);
              runData.offset++;
              return retCode;
            }
            currentLineBitPosition = width;
            continue decodeLoop;
        }

        // Only vertical modes get this far
        if (currentLineBitPosition <= width) {
          whiteRun = !whiteRun;

          runOffsets[currentBufferOffset++] = currentLineBitPosition;

          if (referenceBufferOffset > 0) {
            referenceBufferOffset--;
          } else {
            referenceBufferOffset++;
          }

          while (currentLineBitPosition < width && referenceOffsets[referenceBufferOffset] <= currentLineBitPosition) {
            referenceBufferOffset += 2;
          }
        }
      }
    } on Object catch (error) {
      throw ImageCodecException('Invalid JBIG2 MMR codeword', cause: error);
    }

    if (runOffsets[currentBufferOffset] != width) {
      runOffsets[currentBufferOffset] = width;
    }

    if (code == null) {
      return _Jbig2MmrConstants.endOfLine;
    }
    return currentBufferOffset;
  }

  /// Computes uncompress1 d.
  int uncompress1D(_Jbig2RunData runData, List<int> runOffsets, int width) {
    bool whiteRun = true;
    int iBitPos = 0;
    _Jbig2MmrCode? code;
    int refOffset = 0;

    loop:
    while (iBitPos < width) {
      while (true) {
        if (whiteRun) {
          code = runData.uncompressGetCode(whiteTable!);
        } else {
          code = runData.uncompressGetCode(blackTable!);
        }

        if (code == null) {
          break loop;
        }

        runData.offset += code.bitLength;

        if (code.runLength < 0) {
          break loop;
        }

        iBitPos += code.runLength;

        if (code.runLength < 64) {
          whiteRun = !whiteRun;
          runOffsets[refOffset++] = iBitPos;
          break;
        }
      }
    }

    if (runOffsets[refOffset] != width) {
      runOffsets[refOffset] = width;
    }

    return code != null && code.runLength != _Jbig2MmrConstants.endOfLine ? refOffset : _Jbig2MmrConstants.endOfLine;
  }

  /// Creates little endian table.
  static List<_Jbig2MmrCode?> createLittleEndianTable(List<List<int>> codes) {
    final List<_Jbig2MmrCode?> firstLevelTable = List.filled(firstLevelTableMask + 1, null);
    for (int i = 0; i < codes.length; i++) {
      final _Jbig2MmrCode code = _Jbig2MmrCode(codeData: codes[i]);

      if (code.bitLength <= firstLevelTableSize) {
        final int variantLength = firstLevelTableSize - code.bitLength;
        final int baseWord = code.codeWord << variantLength;

        for (int variant = (1 << variantLength) - 1; variant >= 0; variant--) {
          final int index = baseWord | variant;
          firstLevelTable[index] = code;
        }
      } else {
        // init second level table
        final int firstLevelIndex = code.codeWord >>> (code.bitLength - firstLevelTableSize);

        if (firstLevelTable[firstLevelIndex] == null) {
          final _Jbig2MmrCode firstLevelCode = _Jbig2MmrCode(codeData: [0, 0, 0]); // Dummy
          firstLevelCode.subTable = List.filled(secondLevelTableMask + 1, null);
          firstLevelTable[firstLevelIndex] = firstLevelCode;
        }

        // fill second level table
        if (code.bitLength <= firstLevelTableSize + secondLevelTableSize) {
          final List<_Jbig2MmrCode?> secondLevelTable = firstLevelTable[firstLevelIndex]!.subTable!;
          final int variantLength = firstLevelTableSize + secondLevelTableSize - code.bitLength;
          final int baseWord = (code.codeWord << variantLength) & secondLevelTableMask;

          for (int variant = (1 << variantLength) - 1; variant >= 0; variant--) {
            secondLevelTable[baseWord | variant] = code;
          }
        } else {
          throw ArgumentError('_Jbig2MmrCode table overflow in _Jbig2MmrDecoder');
        }
      }
    }
    return firstLevelTable;
  }
}

/// Implements the JBIG2 run data procedure.
class _Jbig2RunData {
  /// Stores max run data buffer.
  static const int maxRunDataBuffer = 1024 << 7; // 1024 * 128
  /// Stores min run data buffer.
  static const int minRunDataBuffer = 3; // min. bytes to decompress
  /// Stores code offset.
  static const int codeOffset = 24;

  /// Stores stream.
  _Jbig2ByteReader stream;

  /// Stores offset.
  int offset = 0;

  /// Stores last offset.
  int lastOffset = 0;

  /// Stores last code.
  int lastCode = 0;

  /// Stores buffer.
  late Uint8List buffer;

  /// Stores buffer base.
  int bufferBase = 0;

  /// Stores buffer top.
  int bufferTop = 0;

  /// Creates the run data state.
  _Jbig2RunData({
    required this.stream,
  }) {
    offset = 0;
    lastOffset = 1;

    try {
      int len = stream.length;

      len = math.min(math.max(minRunDataBuffer, len), maxRunDataBuffer);

      buffer = Uint8List(len);
      fillBuffer(0);
    } catch (e) {
      throw ImageCodecException('Invalid JBIG2 MMR input', cause: e);
    }
  }

  /// Computes uncompress get code.
  _Jbig2MmrCode? uncompressGetCode(List<_Jbig2MmrCode?> table) => uncompressGetCodeLittleEndian(table);

  /// Computes uncompress get code little endian.
  _Jbig2MmrCode? uncompressGetCodeLittleEndian(List<_Jbig2MmrCode?> table) {
    final int code = uncompressGetNextCodeLittleEndian() & 0xffffff;
    _Jbig2MmrCode? result = table[code >> (codeOffset - _Jbig2MmrDecoder.firstLevelTableSize)];

    // perform second-level lookup
    if (result != null && result.subTable != null) {
      result = result.subTable![(code >> (codeOffset - _Jbig2MmrDecoder.firstLevelTableSize - _Jbig2MmrDecoder.secondLevelTableSize)) & _Jbig2MmrDecoder.secondLevelTableMask];
    }

    return result;
  }

  /// Computes uncompress get next code little endian.
  int uncompressGetNextCodeLittleEndian() {
    try {
      // the number of bits to fill (offset difference)
      int bitsToFill = offset - lastOffset;

      // check whether we can refill, or need to fill in absolute mode
      if (bitsToFill < 0 || bitsToFill > 24) {
        // refill at absolute offset
        int byteOffset = (offset >> 3) - bufferBase; // offset>>3 is equivalent to offset/8

        if (byteOffset >= bufferTop) {
          byteOffset += bufferBase;
          fillBuffer(byteOffset);
          byteOffset -= bufferBase;
        }

        lastCode = (buffer[byteOffset] & 0xff) << 16 | (buffer[byteOffset + 1] & 0xff) << 8 | (buffer[byteOffset + 2] & 0xff);

        final int bitOffset = offset & 7; // equivalent to offset%8
        lastCode <<= bitOffset;
      } else {
        // the offset to the next byte boundary as seen from the last offset
        int bitOffset = lastOffset & 7;
        final int avail = 7 - bitOffset;

        // check whether there are enough bits in the "queue"
        if (bitsToFill <= avail) {
          lastCode <<= bitsToFill;
        } else {
          int byteOffset = (lastOffset >> 3) + 3 - bufferBase;

          if (byteOffset >= bufferTop) {
            byteOffset += bufferBase;
            fillBuffer(byteOffset);
            byteOffset -= bufferBase;
          }

          bitOffset = 8 - bitOffset;
          do {
            lastCode <<= bitOffset;
            lastCode |= buffer[byteOffset] & 0xff;
            bitsToFill -= bitOffset;
            byteOffset++;
            bitOffset = 8;
          } while (bitsToFill >= 8);

          lastCode <<= bitsToFill; // shift the rest
        }
      }
      lastOffset = offset;

      return lastCode;
    } catch (e) {
      throw RangeError('Corrupted RLE data caused by an IOException while reading raw data: $e');
    }
  }

  /// Fills buffer.
  void fillBuffer(int byteOffset) {
    bufferBase = byteOffset;
    try {
      stream.seek(byteOffset);

      // It has readBuffer(buffer)
      bufferTop = stream.readBuffer(buffer);
    } catch (e) {
      // you never know which kind of endOfFile will kick in
      bufferTop = -1;
    }
    // check filling degree
    if (bufferTop > -1 && bufferTop < 3) {
      // CK: if filling degree is too small,
      // smoothly fill up to the next three bytes or substitute with with
      // empty bytes
      int read = 0;
      while (bufferTop < 3) {
        try {
          read = stream.read();
        } catch (e) {
          read = -1;
        }
        buffer[bufferTop++] = read == -1 ? 0 : (read & 0xff);
      }
    }

    // leave some room, in order to save a few tests in the calling code
    bufferTop -= 3;

    if (bufferTop < 0) {
      // if we're at endOfFile, just supply zero-bytes
      buffer.fillRange(0, buffer.length, 0);
      bufferTop = buffer.length - 3;
    }
  }

  /// Computes align.
  void align() {
    offset = ((offset + 7) >> 3) << 3;
  }
}

/// Implements the JBIG2 mmr code procedure.
class _Jbig2MmrCode {
  /// Stores sub table.
  List<_Jbig2MmrCode?>? subTable;

  /// Stores bit length.
  final int bitLength;

  /// Stores code word.
  final int codeWord;

  /// Stores run length.
  final int runLength;

  /// Creates the mmr code state.
  _Jbig2MmrCode({
    required List<int> codeData,
  }) : bitLength = codeData[0],
       codeWord = codeData[1],
       runLength = codeData[2];

  @override
  String toString() => '$bitLength/$codeWord/$runLength';

  @override
  bool operator ==(Object other) => (other is _Jbig2MmrCode) && other.bitLength == bitLength && other.codeWord == codeWord && other.runLength == runLength;

  @override
  int get hashCode => Object.hash(bitLength, codeWord, runLength);
}
