part of '../tiff.dart';

/// Decodes baseline TIFF images to straight RGBA pixels.
final class TiffDecoder extends RasterDecoder {
  /// Byte sizes indexed by TIFF field type.
  static const Map<int, int> _typeSizes = {
    1: 1,
    2: 1,
    3: 2,
    4: 4,
    5: 8,
    6: 1,
    7: 1,
    8: 2,
    9: 4,
    10: 8,
    11: 4,
    12: 8,
  };

  /// Creates a baseline TIFF decoder.
  const TiffDecoder();

  /// Decodes the first image-file directory in [bytes].
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    if (maxPixels < 1) {
      throw RangeError.range(maxPixels, 1, null, 'maxPixels');
    }
    if (bytes.length < 8) {
      throw const ImageCodecException('The TIFF header is truncated');
    }
    final Endian endian = _readEndian(bytes);
    final ByteData data = ByteData.sublistView(bytes);
    if (data.getUint16(2, endian) != 42) {
      throw const ImageCodecException('Invalid TIFF version');
    }
    final int directoryOffset = data.getUint32(4, endian);
    final Map<int, _TiffField> fields = _readDirectory(bytes, data, endian, directoryOffset);
    final int width = _requiredScalar(fields, 256);
    final int height = _requiredScalar(fields, 257);
    _checkDimensions(width, height, maxPixels);

    final int compression = _scalar(fields, 259, fallback: 1);
    final int photometric = _requiredScalar(fields, 262);
    final int orientation = _scalar(fields, 274, fallback: 1);
    final int samplesPerPixel = _scalar(fields, 277, fallback: 1);
    final int rowsPerStrip = _scalar(fields, 278, fallback: height);
    final int planarConfiguration = _scalar(fields, 284, fallback: 1);
    final int predictor = _scalar(fields, 317, fallback: 1);
    final List<int> bitsPerSample = _values(fields[258]) ?? [1];
    final List<int> stripOffsets = _requiredValues(fields, 273);
    final List<int> stripByteCounts = _requiredValues(fields, 279);
    final List<int> extraSamples = _values(fields[338]) ?? const [];

    if (orientation < 1 || orientation > 8) {
      throw ImageCodecException('Unsupported TIFF orientation: $orientation');
    }
    if (rowsPerStrip < 1 || samplesPerPixel < 1) {
      throw const ImageCodecException('Invalid TIFF sample or strip dimensions');
    }
    if (planarConfiguration != 1) {
      throw const ImageCodecException('Planar TIFF images are not supported');
    }
    if (predictor != 1 && predictor != 2) {
      throw ImageCodecException('Unsupported TIFF predictor: $predictor');
    }
    if (stripOffsets.length != stripByteCounts.length) {
      throw const ImageCodecException('TIFF strip offset and byte-count arrays differ in length');
    }
    if (bitsPerSample.length != 1 && bitsPerSample.length != samplesPerPixel) {
      throw const ImageCodecException('TIFF BitsPerSample does not match SamplesPerPixel');
    }
    if (bitsPerSample.any((bits) => bits != 8)) {
      throw const ImageCodecException('Only eight-bit TIFF samples are supported');
    }

    final int rowBytes = width * samplesPerPixel;
    final Uint8List samples = Uint8List(rowBytes * height);
    int decodedRow = 0;
    for (int strip = 0; strip < stripOffsets.length && decodedRow < height; strip++) {
      final int rowCount = _minimum(rowsPerStrip, height - decodedRow);
      final int expectedLength = rowCount * rowBytes;
      final Uint8List encoded = _slice(bytes, stripOffsets[strip], stripByteCounts[strip]);
      final Uint8List decoded = _decodeStrip(encoded, compression, expectedLength);
      if (decoded.length != expectedLength) {
        throw const ImageCodecException('A TIFF strip has an unexpected decoded size');
      }
      if (predictor == 2) {
        _undoHorizontalPredictor(decoded, rowBytes, samplesPerPixel);
      }
      samples.setRange(decodedRow * rowBytes, (decodedRow + rowCount) * rowBytes, decoded);
      decodedRow += rowCount;
    }
    if (decodedRow != height) {
      throw const ImageCodecException('TIFF strips do not cover the declared image height');
    }

    final List<int>? colorMap = _values(fields[320]);
    final Uint8List rgba = _convertToRgba(
      samples,
      width: width,
      height: height,
      samplesPerPixel: samplesPerPixel,
      photometric: photometric,
      colorMap: colorMap,
      associatedAlpha: extraSamples.isNotEmpty && extraSamples.first == 1,
    );
    return _orient(rgba, width, height, orientation);
  }

  /// Determines byte order from the two-byte TIFF signature.
  Endian _readEndian(Uint8List bytes) {
    if (bytes[0] == 0x49 && bytes[1] == 0x49) {
      return Endian.little;
    }
    if (bytes[0] == 0x4d && bytes[1] == 0x4d) {
      return Endian.big;
    }
    throw const ImageCodecException('Invalid TIFF byte-order signature');
  }

  /// Reads and validates every entry in one image-file directory.
  Map<int, _TiffField> _readDirectory(Uint8List bytes, ByteData data, Endian endian, int offset) {
    _ensureRange(bytes, offset, 2);
    final int entryCount = data.getUint16(offset, endian);
    _ensureRange(bytes, offset + 2, entryCount * 12 + 4);
    final Map<int, _TiffField> result = {};
    for (int index = 0; index < entryCount; index++) {
      final int entryOffset = offset + 2 + index * 12;
      final int tag = data.getUint16(entryOffset, endian);
      final int type = data.getUint16(entryOffset + 2, endian);
      final int count = data.getUint32(entryOffset + 4, endian);
      final int? typeSize = _typeSizes[type];
      if (typeSize == null || count > bytes.length) {
        continue;
      }
      final int byteLength = count * typeSize;
      final int valueOffset = byteLength <= 4 ? entryOffset + 8 : data.getUint32(entryOffset + 8, endian);
      _ensureRange(bytes, valueOffset, byteLength);
      result[tag] = _TiffField(bytes: bytes, data: data, endian: endian, type: type, count: count, offset: valueOffset);
    }
    return result;
  }

  /// Returns all unsigned integer values represented by [field].
  List<int>? _values(_TiffField? field) {
    if (field == null) {
      return null;
    }
    if (field.type != 1 && field.type != 3 && field.type != 4) {
      throw ImageCodecException('Unsupported integer TIFF field type: ${field.type}');
    }
    return List<int>.generate(field.count, (index) => field.unsignedAt(index), growable: false);
  }

  /// Returns a required integer field or reports its missing tag.
  List<int> _requiredValues(Map<int, _TiffField> fields, int tag) {
    final List<int>? values = _values(fields[tag]);
    if (values == null || values.isEmpty) {
      throw ImageCodecException('Required TIFF tag $tag is missing');
    }
    return values;
  }

  /// Returns a required scalar integer field.
  int _requiredScalar(Map<int, _TiffField> fields, int tag) => _requiredValues(fields, tag).first;

  /// Returns a scalar integer field or [fallback] when absent.
  int _scalar(Map<int, _TiffField> fields, int tag, {required int fallback}) => _values(fields[tag])?.firstOrNull ?? fallback;

  /// Rejects dimensions that are invalid or exceed the allocation limit.
  void _checkDimensions(int width, int height, int maxPixels) {
    if (width < 1 || height < 1) {
      throw const ImageCodecException('TIFF dimensions must be non-zero');
    }
    final int pixelCount = width * height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
  }

  /// Returns a bounds-checked byte view.
  Uint8List _slice(Uint8List bytes, int offset, int length) {
    _ensureRange(bytes, offset, length);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  /// Ensures a file range lies inside the encoded data.
  void _ensureRange(Uint8List bytes, int offset, int length) {
    if (offset < 0 || length < 0 || offset > bytes.length - length) {
      throw const ImageCodecException('A TIFF offset points outside the encoded data');
    }
  }

  /// Decodes one TIFF strip according to its compression tag.
  Uint8List _decodeStrip(Uint8List encoded, int compression, int expectedLength) => switch (compression) {
    1 => Uint8List.fromList(encoded),
    5 => _decodeLzw(encoded, expectedLength),
    32773 => _decodePackBits(encoded, expectedLength),
    _ => throw ImageCodecException('Unsupported TIFF compression: $compression'),
  };

  /// Decodes TIFF PackBits packets.
  Uint8List _decodePackBits(Uint8List encoded, int expectedLength) {
    final Uint8List output = Uint8List(expectedLength);
    int inputPosition = 0;
    int outputPosition = 0;
    while (inputPosition < encoded.length && outputPosition < expectedLength) {
      final int header = encoded[inputPosition++];
      if (header <= 127) {
        final int length = header + 1;
        if (inputPosition > encoded.length - length || outputPosition > expectedLength - length) {
          throw const ImageCodecException('Invalid TIFF PackBits literal packet');
        }
        output.setRange(outputPosition, outputPosition + length, encoded, inputPosition);
        inputPosition += length;
        outputPosition += length;
      } else if (header >= 129) {
        final int length = 257 - header;
        if (inputPosition >= encoded.length || outputPosition > expectedLength - length) {
          throw const ImageCodecException('Invalid TIFF PackBits run packet');
        }
        output.fillRange(outputPosition, outputPosition + length, encoded[inputPosition++]);
        outputPosition += length;
      }
    }
    if (outputPosition != expectedLength) {
      throw const ImageCodecException('A TIFF PackBits strip is truncated');
    }
    return output;
  }

  /// Decodes TIFF-flavoured LZW with early code-width changes.
  Uint8List _decodeLzw(Uint8List encoded, int expectedLength) {
    final _TiffBitReader reader = _TiffBitReader(bytes: encoded);
    final Uint8List output = Uint8List(expectedLength);
    List<Uint8List> dictionary = _initialLzwDictionary();
    int codeWidth = 9;
    int nextCode = 258;
    int outputPosition = 0;
    Uint8List? previous;
    while (true) {
      final int? code = reader.read(codeWidth);
      if (code == null) {
        break;
      }
      if (code == 256) {
        dictionary = _initialLzwDictionary();
        codeWidth = 9;
        nextCode = 258;
        previous = null;
        continue;
      }
      if (code == 257) {
        break;
      }
      final Uint8List value;
      if (code < dictionary.length && dictionary[code].isNotEmpty) {
        value = dictionary[code];
      } else if (code == nextCode && previous != null) {
        value = Uint8List(previous.length + 1)
          ..setRange(0, previous.length, previous)
          ..last = previous.first;
      } else {
        throw const ImageCodecException('Invalid TIFF LZW code');
      }
      if (outputPosition > expectedLength - value.length) {
        throw const ImageCodecException('TIFF LZW output exceeds the strip size');
      }
      output.setRange(outputPosition, outputPosition + value.length, value);
      outputPosition += value.length;
      if (previous != null && nextCode < 4096) {
        final Uint8List addition = Uint8List(previous.length + 1)
          ..setRange(0, previous.length, previous)
          ..last = value.first;
        if (nextCode == dictionary.length) {
          dictionary.add(addition);
        } else {
          dictionary[nextCode] = addition;
        }
        nextCode++;
        if (nextCode == (1 << codeWidth) - 1 && codeWidth < 12) {
          codeWidth++;
        }
      }
      previous = value;
    }
    if (outputPosition != expectedLength) {
      throw const ImageCodecException('A TIFF LZW strip is truncated');
    }
    return output;
  }

  /// Creates the initial single-byte LZW dictionary plus control placeholders.
  List<Uint8List> _initialLzwDictionary() => List<Uint8List>.generate(
    258,
    (index) => index < 256 ? Uint8List.fromList([index]) : Uint8List(0),
    growable: true,
  );

  /// Reverses the horizontal differencing predictor in-place.
  void _undoHorizontalPredictor(Uint8List bytes, int rowBytes, int samplesPerPixel) {
    for (int rowOffset = 0; rowOffset < bytes.length; rowOffset += rowBytes) {
      for (int offset = rowOffset + samplesPerPixel; offset < rowOffset + rowBytes; offset++) {
        bytes[offset] = (bytes[offset] + bytes[offset - samplesPerPixel]) & 0xff;
      }
    }
  }

  /// Converts supported TIFF photometric interpretations to straight RGBA.
  Uint8List _convertToRgba(
    Uint8List samples, {
    required int width,
    required int height,
    required int samplesPerPixel,
    required int photometric,
    required List<int>? colorMap,
    required bool associatedAlpha,
  }) {
    final int pixelCount = width * height;
    final Uint8List rgba = Uint8List(pixelCount * 4);
    for (int pixel = 0; pixel < pixelCount; pixel++) {
      final int source = pixel * samplesPerPixel;
      final int destination = pixel * 4;
      int red;
      int green;
      int blue;
      int alpha = 255;
      switch (photometric) {
        case 0:
        case 1:
          if (samplesPerPixel != 1 && samplesPerPixel != 2) {
            throw const ImageCodecException('Invalid grayscale TIFF sample count');
          }
          final int gray = photometric == 0 ? 255 - samples[source] : samples[source];
          red = gray;
          green = gray;
          blue = gray;
          if (samplesPerPixel == 2) {
            alpha = samples[source + 1];
          }
        case 2:
          if (samplesPerPixel != 3 && samplesPerPixel != 4) {
            throw const ImageCodecException('Invalid RGB TIFF sample count');
          }
          red = samples[source];
          green = samples[source + 1];
          blue = samples[source + 2];
          if (samplesPerPixel == 4) {
            alpha = samples[source + 3];
          }
        case 3:
          if (samplesPerPixel != 1 || colorMap == null || colorMap.length % 3 != 0) {
            throw const ImageCodecException('Invalid palette TIFF data');
          }
          final int paletteLength = colorMap.length ~/ 3;
          final int paletteIndex = samples[source];
          if (paletteIndex >= paletteLength) {
            throw const ImageCodecException('A TIFF palette index is out of range');
          }
          red = colorMap[paletteIndex] >>> 8;
          green = colorMap[paletteLength + paletteIndex] >>> 8;
          blue = colorMap[paletteLength * 2 + paletteIndex] >>> 8;
        default:
          throw ImageCodecException('Unsupported TIFF photometric interpretation: $photometric');
      }
      if (associatedAlpha && alpha != 0 && alpha != 255) {
        red = _minimum(255, (red * 255 + alpha ~/ 2) ~/ alpha);
        green = _minimum(255, (green * 255 + alpha ~/ 2) ~/ alpha);
        blue = _minimum(255, (blue * 255 + alpha ~/ 2) ~/ alpha);
      }
      rgba[destination] = red;
      rgba[destination + 1] = green;
      rgba[destination + 2] = blue;
      rgba[destination + 3] = alpha;
    }
    return rgba;
  }

  /// Applies a TIFF orientation and returns correctly dimensioned image data.
  Image _orient(Uint8List source, int width, int height, int orientation) {
    final bool swapsAxes = orientation >= 5;
    final int outputWidth = swapsAxes ? height : width;
    final int outputHeight = swapsAxes ? width : height;
    if (orientation == 1) {
      return Image.fromRgba(width: width, height: height, bytes: source, copy: false);
    }
    final Uint8List output = Uint8List(source.length);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final (int outputX, int outputY) = switch (orientation) {
          2 => (width - 1 - x, y),
          3 => (width - 1 - x, height - 1 - y),
          4 => (x, height - 1 - y),
          5 => (y, x),
          6 => (height - 1 - y, x),
          7 => (height - 1 - y, width - 1 - x),
          8 => (y, width - 1 - x),
          _ => (x, y),
        };
        final int sourceOffset = (y * width + x) * 4;
        final int destinationOffset = (outputY * outputWidth + outputX) * 4;
        output.setRange(destinationOffset, destinationOffset + 4, source, sourceOffset);
      }
    }
    return Image.fromRgba(width: outputWidth, height: outputHeight, bytes: output, copy: false);
  }

  /// Returns the smaller integer.
  int _minimum(int first, int second) => first < second ? first : second;
}

/// Holds one TIFF directory field and its typed value location.
final class _TiffField {
  /// Complete encoded TIFF bytes.
  final Uint8List bytes;

  /// Typed view over [bytes].
  final ByteData data;

  /// Byte order used by integer values.
  final Endian endian;

  /// TIFF field type number.
  final int type;

  /// Number of values in the field.
  final int count;

  /// Absolute offset of the first field value.
  final int offset;

  /// Creates a parsed TIFF directory field.
  const _TiffField({
    required this.bytes,
    required this.data,
    required this.endian,
    required this.type,
    required this.count,
    required this.offset,
  });

  /// Reads one unsigned integer value.
  int unsignedAt(int index) {
    if (index < 0 || index >= count) {
      throw RangeError.index(index, this, 'index');
    }
    return switch (type) {
      1 => bytes[offset + index],
      3 => data.getUint16(offset + index * 2, endian),
      4 => data.getUint32(offset + index * 4, endian),
      _ => throw ImageCodecException('TIFF field type $type is not an unsigned integer'),
    };
  }
}

/// Reads most-significant-bit-first codes from a TIFF LZW strip.
final class _TiffBitReader {
  /// Encoded strip bytes.
  final Uint8List bytes;

  /// Current bit offset.
  int _bitPosition = 0;

  /// Creates a TIFF bit reader.
  _TiffBitReader({required this.bytes});

  /// Reads [width] bits or returns `null` when the strip has ended.
  int? read(int width) {
    if (_bitPosition + width > bytes.length * 8) {
      return null;
    }
    int value = 0;
    for (int bit = 0; bit < width; bit++) {
      final int byte = bytes[_bitPosition >>> 3];
      value = (value << 1) | ((byte >>> (7 - (_bitPosition & 7))) & 1);
      _bitPosition++;
    }
    return value;
  }
}
