part of '../gif.dart';

/// Encodes palette indices with GIF's least-significant-bit-first LZW stream.
abstract final class _GifLzwEncoder {
  /// Encodes [indices] with one clear code and a bounded 12-bit dictionary.
  static Uint8List encode(
    Uint8List indices, {
    required int minimumCodeSize,
  }) {
    _validateMinimumCodeSize(minimumCodeSize);
    final int clearCode = 1 << minimumCodeSize;
    final int endCode = clearCode + 1;
    final _GifBitWriter output = _GifBitWriter();
    final Map<int, int> dictionary = {};
    int codeSize = minimumCodeSize + 1;
    int nextCode = endCode + 1;
    int codeLimit = 1 << codeSize;
    output.write(clearCode, codeSize);
    if (indices.isEmpty) {
      output.write(endCode, codeSize);
      return output.takeBytes();
    }
    int prefix = indices.first;
    for (int position = 1; position < indices.length; position++) {
      final int symbol = indices[position];
      final int key = prefix << 8 | symbol;
      final int? existing = dictionary[key];
      if (existing != null) {
        prefix = existing;
        continue;
      }
      output.write(prefix, codeSize);
      if (nextCode < 4096) {
        dictionary[key] = nextCode++;
        // The newly inserted code need not fit until it can be emitted by a
        // later iteration. Grow only after that code exhausts the current
        // width; this is GIF's code-width convention rather than TIFF's.
        if (nextCode > codeLimit && codeSize < 12) {
          codeSize++;
          codeLimit <<= 1;
        }
      } else {
        output.write(clearCode, codeSize);
        dictionary.clear();
        codeSize = minimumCodeSize + 1;
        nextCode = endCode + 1;
        codeLimit = 1 << codeSize;
      }
      prefix = symbol;
    }
    output
      ..write(prefix, codeSize)
      ..write(endCode, codeSize);
    return output.takeBytes();
  }
}

/// Decodes GIF LZW codes into a fixed number of palette indices.
abstract final class _GifLzwDecoder {
  /// Expands [bytes] and requires exactly [expectedLength] output indices.
  static Uint8List decode(
    Uint8List bytes, {
    required int minimumCodeSize,
    required int expectedLength,
  }) {
    _validateMinimumCodeSize(minimumCodeSize);
    final int clearCode = 1 << minimumCodeSize;
    final int endCode = clearCode + 1;
    final Int16List prefixes = Int16List(4096);
    final Uint8List suffixes = Uint8List(4096);
    final Uint8List stack = Uint8List(4097);
    for (int index = 0; index < clearCode; index++) {
      suffixes[index] = index;
    }
    final _GifBitReader input = _GifBitReader(bytes);
    final Uint8List output = Uint8List(expectedLength);
    int outputPosition = 0;
    int codeSize = minimumCodeSize + 1;
    int nextCode = endCode + 1;
    int oldCode = -1;
    int firstSymbol = 0;
    bool reachedEnd = false;
    while (true) {
      final int? readCode = input.read(codeSize);
      if (readCode == null) {
        break;
      }
      if (readCode == clearCode) {
        codeSize = minimumCodeSize + 1;
        nextCode = endCode + 1;
        oldCode = -1;
        continue;
      }
      if (readCode == endCode) {
        reachedEnd = true;
        break;
      }
      if (oldCode < 0) {
        if (readCode >= clearCode) {
          throw const ImageCodecException('GIF LZW stream starts with an invalid code');
        }
        outputPosition = _writeDecodedByte(
          output,
          outputPosition,
          readCode,
        );
        firstSymbol = readCode;
        oldCode = readCode;
        continue;
      }

      final int originalCode = readCode;
      int code = readCode;
      int stackLength = 0;
      if (code == nextCode) {
        stack[stackLength++] = firstSymbol;
        code = oldCode;
      } else if (code > nextCode) {
        throw const ImageCodecException('GIF LZW stream references a future code');
      }
      while (code >= clearCode) {
        if (code >= nextCode || stackLength >= stack.length) {
          throw const ImageCodecException('GIF LZW dictionary is invalid');
        }
        stack[stackLength++] = suffixes[code];
        code = prefixes[code];
      }
      firstSymbol = code;
      stack[stackLength++] = firstSymbol;
      while (stackLength > 0) {
        outputPosition = _writeDecodedByte(
          output,
          outputPosition,
          stack[--stackLength],
        );
      }
      if (nextCode < 4096) {
        prefixes[nextCode] = oldCode;
        suffixes[nextCode] = firstSymbol;
        nextCode++;
        if (nextCode == (1 << codeSize) && codeSize < 12) {
          codeSize++;
        }
      }
      oldCode = originalCode;
    }
    if (!reachedEnd) {
      throw const ImageCodecException('GIF LZW stream has no end code');
    }
    if (outputPosition != expectedLength) {
      throw ImageCodecException(
        'GIF frame decoded $outputPosition pixels, expected $expectedLength',
      );
    }
    return output;
  }

  /// Appends one byte or rejects data beyond the declared frame size.
  static int _writeDecodedByte(
    Uint8List output,
    int position,
    int value,
  ) {
    if (position >= output.length) {
      throw const ImageCodecException(
        'GIF LZW stream exceeds the declared frame size',
      );
    }
    output[position] = value;
    return position + 1;
  }
}

/// Rejects code sizes outside the GIF specification.
void _validateMinimumCodeSize(int minimumCodeSize) {
  if (minimumCodeSize < 2 || minimumCodeSize > 8) {
    throw ImageCodecException(
      'GIF LZW minimum code size must be between 2 and 8, received $minimumCodeSize',
    );
  }
}

/// Writes variable-width integers least-significant bit first.
final class _GifBitWriter {
  /// Completed bytes.
  final OutputBuffer _output = OutputBuffer();

  /// Pending low-order bits.
  int _bits = 0;

  /// Number of valid pending bits.
  int _bitCount = 0;

  /// Appends [value] using [width] low-order bits.
  void write(int value, int width) {
    _bits |= value << _bitCount;
    _bitCount += width;
    while (_bitCount >= 8) {
      _output.writeByte(_bits);
      _bits >>>= 8;
      _bitCount -= 8;
    }
  }

  /// Flushes the final partial byte and returns all data.
  Uint8List takeBytes() {
    if (_bitCount > 0) {
      _output.writeByte(_bits);
      _bits = 0;
      _bitCount = 0;
    }
    return _output.takeBytes();
  }
}

/// Reads variable-width integers least-significant bit first.
final class _GifBitReader {
  /// Encoded LZW bytes.
  final Uint8List _bytes;

  /// Next unread byte.
  int _position = 0;

  /// Pending low-order bits.
  int _bits = 0;

  /// Number of valid pending bits.
  int _bitCount = 0;

  /// Creates a reader over [bytes].
  _GifBitReader(this._bytes);

  /// Reads one [width]-bit code, or `null` after the last complete code.
  int? read(int width) {
    while (_bitCount < width) {
      if (_position >= _bytes.length) {
        return null;
      }
      _bits |= _bytes[_position++] << _bitCount;
      _bitCount += 8;
    }
    final int value = _bits & ((1 << width) - 1);
    _bits >>>= width;
    _bitCount -= width;
    return value;
  }
}
