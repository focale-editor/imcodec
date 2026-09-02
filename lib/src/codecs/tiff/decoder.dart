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
    final _TiffRaster raster = _decodeRaster(bytes, maxPixels: maxPixels);
    if (raster.colorModel != DecodedColorModel.rgb || raster.samples.format != DecodedSampleFormat.uint8) {
      return raster.toDecodedImage().toImage();
    }
    // The samples were allocated here and are handed straight to the image,
    // which skips the defensive copy an immutable raster would require.
    return Image.fromRgba(
      width: raster.orientedWidth,
      height: raster.orientedHeight,
      bytes: raster.orientedBytes(),
      copy: false,
    );
  }

  /// Decodes TIFF samples without reducing unsigned sixteen-bit or float data.
  DecodedImage decodeData(Uint8List bytes, {required int maxPixels}) => _decodeRaster(bytes, maxPixels: maxPixels).toDecodedImage();

  /// Decodes the first image-file directory into still unoriented samples.
  _TiffRaster _decodeRaster(Uint8List bytes, {required int maxPixels}) {
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
    final _TiffField? bitsPerSampleField = fields[258];
    // Some writers omit SamplesPerPixel; BitsPerSample already implies it.
    final int samplesPerPixel = _scalar(
      fields,
      277,
      fallback: bitsPerSampleField?.count ?? 1,
    );
    final int rowsPerStrip = _scalar(fields, 278, fallback: height);
    final int planarConfiguration = _scalar(fields, 284, fallback: 1);
    final int predictor = _scalar(fields, 317, fallback: 1);
    if (orientation < 1 || orientation > 8) {
      throw ImageCodecException('Unsupported TIFF orientation: $orientation');
    }
    if (rowsPerStrip < 1 || samplesPerPixel < 1) {
      throw const ImageCodecException(
        'Invalid TIFF sample or strip dimensions',
      );
    }
    if (samplesPerPixel > 5) {
      throw const ImageCodecException('Invalid TIFF sample count');
    }
    if (planarConfiguration != 1) {
      throw const ImageCodecException(
        'Planar TIFF images are not supported',
      );
    }
    if (predictor != 1 && predictor != 2) {
      throw ImageCodecException('Unsupported TIFF predictor: $predictor');
    }
    if (bitsPerSampleField != null && bitsPerSampleField.count != 1 && bitsPerSampleField.count != samplesPerPixel) {
      throw const ImageCodecException(
        'TIFF BitsPerSample does not match SamplesPerPixel',
      );
    }
    final _TiffField? sampleFormatField = fields[339];
    if (sampleFormatField != null && sampleFormatField.count != 1 && sampleFormatField.count != samplesPerPixel) {
      throw const ImageCodecException(
        'TIFF SampleFormat does not match SamplesPerPixel',
      );
    }
    final _TiffField? extraSamplesField = fields[338];
    if (extraSamplesField != null && extraSamplesField.count > 1) {
      throw const ImageCodecException(
        'Multiple TIFF extra samples are not supported',
      );
    }
    final int expectedStripCount = (height + rowsPerStrip - 1) ~/ rowsPerStrip;
    final _TiffField? stripOffsetsField = fields[273];
    final _TiffField? stripByteCountsField = fields[279];
    if (stripOffsetsField == null || stripByteCountsField == null || stripOffsetsField.count != expectedStripCount || stripByteCountsField.count != expectedStripCount) {
      throw const ImageCodecException(
        'TIFF strip tables do not match the declared rows',
      );
    }

    final List<int> bitsPerSampleValues = _values(bitsPerSampleField) ?? const [1];
    final List<int> bitsPerSample = bitsPerSampleValues;
    final List<int> stripOffsets = _requiredValues(fields, 273);
    final List<int> stripByteCounts = _requiredValues(fields, 279);
    final List<int> extraSamples = _values(extraSamplesField) ?? const [];
    final List<int> sampleFormats = _values(sampleFormatField) ?? const [1];

    if (stripOffsets.length != stripByteCounts.length) {
      throw const ImageCodecException('TIFF strip offset and byte-count arrays differ in length');
    }
    if (bitsPerSample.length != 1 && bitsPerSample.length != samplesPerPixel) {
      throw const ImageCodecException('TIFF BitsPerSample does not match SamplesPerPixel');
    }
    if (sampleFormats.isEmpty || sampleFormats.length != 1 && sampleFormats.length != samplesPerPixel) {
      throw const ImageCodecException(
        'TIFF SampleFormat does not match SamplesPerPixel',
      );
    }
    final int sampleBits = bitsPerSample.first;
    if (bitsPerSample.any((bits) => bits != sampleBits)) {
      throw const ImageCodecException('TIFF samples of mixed widths are not supported');
    }
    final int sampleRepresentation = sampleFormats.first;
    if (sampleFormats.any(
      (format) => format != sampleRepresentation,
    )) {
      throw const ImageCodecException(
        'TIFF samples of mixed numeric formats are not supported',
      );
    }
    if (sampleRepresentation != 1 && sampleRepresentation != 3) {
      throw ImageCodecException(
        'Unsupported TIFF sample format: $sampleRepresentation',
      );
    }
    if (![1, 2, 4, 8, 16].contains(sampleBits) && !(sampleBits == 32 && sampleRepresentation == 3)) {
      throw ImageCodecException('Unsupported TIFF sample width: $sampleBits bits');
    }
    if (predictor == 2 && (sampleRepresentation != 1 || sampleBits != 8 && sampleBits != 16)) {
      throw const ImageCodecException('The TIFF horizontal predictor requires eight-bit or sixteen-bit samples');
    }
    final _TiffField? colorMapField = fields[320];
    if (photometric == 3 && (colorMapField == null || colorMapField.type != 3 || colorMapField.count != 3 * (1 << sampleBits))) {
      throw const ImageCodecException(
        'Invalid palette TIFF color map',
      );
    }
    final List<int>? colorMap = photometric == 3 ? _values(colorMapField) : null;
    // Reject impossible channel layouts before their declared row size drives
    // a pixel-buffer allocation.
    _validateSampleLayout(
      photometric,
      samplesPerPixel,
      colorMap,
    );

    final DecodedSampleFormat outputFormat = switch ((
      sampleRepresentation,
      sampleBits,
    )) {
      (3, 32) => DecodedSampleFormat.float32,
      (_, 16) => DecodedSampleFormat.uint16,
      _ => DecodedSampleFormat.uint8,
    };

    // Rows are padded to whole bytes, so narrow samples need their own stride.
    final int packedRowBytes = (width * samplesPerPixel * sampleBits + 7) ~/ 8;
    final int rowBytes = width * samplesPerPixel;
    final _TiffSampleBuffer samples = _TiffSampleBuffer(
      rowBytes * height,
      outputFormat,
    );
    int decodedRow = 0;
    for (int strip = 0; strip < stripOffsets.length && decodedRow < height; strip++) {
      final int rowCount = _minimum(rowsPerStrip, height - decodedRow);
      final int expectedLength = rowCount * packedRowBytes;
      final Uint8List encoded = _slice(bytes, stripOffsets[strip], stripByteCounts[strip]);
      final Uint8List decoded = _decodeStrip(encoded, compression, expectedLength);
      if (decoded.length != expectedLength) {
        throw const ImageCodecException('A TIFF strip has an unexpected decoded size');
      }
      if (predictor == 2) {
        _undoHorizontalPredictor(decoded, packedRowBytes, samplesPerPixel * (sampleBits ~/ 8), sampleBits, endian);
      }
      _expandSamples(
        decoded,
        samples,
        decodedRow * rowBytes,
        rowCount,
        rowBytes,
        packedRowBytes,
        sampleBits,
        sampleRepresentation,
        endian,
        photometric == 3,
      );
      decodedRow += rowCount;
    }
    if (decodedRow != height) {
      throw const ImageCodecException('TIFF strips do not cover the declared image height');
    }

    return _convertToRaster(
      samples,
      width: width,
      height: height,
      orientation: orientation,
      samplesPerPixel: samplesPerPixel,
      photometric: photometric,
      colorMap: colorMap,
      associatedAlpha: extraSamples.isNotEmpty && extraSamples.first == 1,
    );
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
  int _requiredScalar(Map<int, _TiffField> fields, int tag) {
    final _TiffField? field = fields[tag];
    if (field == null || field.count < 1) {
      throw ImageCodecException('Required TIFF tag $tag is missing');
    }
    return _firstValue(field);
  }

  /// Returns a scalar integer field or [fallback] when absent.
  int _scalar(
    Map<int, _TiffField> fields,
    int tag, {
    required int fallback,
  }) {
    final _TiffField? field = fields[tag];
    return field == null || field.count < 1 ? fallback : _firstValue(field);
  }

  /// Reads the first scalar without materializing an attacker-sized list.
  int _firstValue(_TiffField field) {
    if (field.type != 1 && field.type != 3 && field.type != 4) {
      throw ImageCodecException(
        'Unsupported integer TIFF field type: ${field.type}',
      );
    }
    return field.unsignedAt(0);
  }

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
  /// Dictionary entries are stored as prefix and suffix links rather than as
  /// byte lists, so growing the dictionary never copies previous entries.
  Uint8List _decodeLzw(Uint8List encoded, int expectedLength) {
    const int clearCode = 256;
    const int endCode = 257;
    const int maximumCode = 4096;
    final Int32List prefixes = Int32List(maximumCode);
    final Uint8List suffixes = Uint8List(maximumCode);
    final Uint8List lengths = Uint8List(maximumCode);
    final Uint8List stack = Uint8List(maximumCode);
    final Uint8List output = Uint8List(expectedLength);
    int codeWidth = 9;
    int nextCode = 258;
    int outputPosition = 0;
    int previousCode = -1;
    int bitPosition = 0;
    final int bitLimit = encoded.length * 8;

    while (bitPosition + codeWidth <= bitLimit) {
      int code = 0;
      for (int bit = 0; bit < codeWidth; bit++) {
        code = (code << 1) | ((encoded[bitPosition >>> 3] >>> (7 - (bitPosition & 7))) & 1);
        bitPosition++;
      }
      if (code == clearCode) {
        codeWidth = 9;
        nextCode = 258;
        previousCode = -1;
        continue;
      }
      if (code == endCode) {
        break;
      }

      final int entry;
      if (code < 256) {
        entry = code;
      } else if (code < nextCode) {
        entry = code;
      } else if (code == nextCode && previousCode >= 0) {
        entry = -1;
      } else {
        throw const ImageCodecException('Invalid TIFF LZW code');
      }

      // Unwind the dictionary chain onto a stack, then emit it in order.
      int stackTop = 0;
      if (entry < 0) {
        stack[stackTop++] = _firstByte(prefixes, suffixes, previousCode);
        int current = previousCode;
        while (current >= 256) {
          stack[stackTop++] = suffixes[current];
          current = prefixes[current];
        }
        stack[stackTop++] = current;
      } else {
        int current = entry;
        while (current >= 256) {
          stack[stackTop++] = suffixes[current];
          current = prefixes[current];
        }
        stack[stackTop++] = current;
      }
      if (outputPosition > expectedLength - stackTop) {
        throw const ImageCodecException('TIFF LZW output exceeds the strip size');
      }
      for (int index = stackTop - 1; index >= 0; index--) {
        output[outputPosition++] = stack[index];
      }

      if (previousCode >= 0 && nextCode < maximumCode) {
        prefixes[nextCode] = previousCode;
        suffixes[nextCode] = stack[stackTop - 1];
        lengths[nextCode] = 0;
        nextCode++;
        if (nextCode == (1 << codeWidth) - 1 && codeWidth < 12) {
          codeWidth++;
        }
      }
      previousCode = code;
    }
    if (outputPosition != expectedLength) {
      throw const ImageCodecException('A TIFF LZW strip is truncated');
    }
    return output;
  }

  /// Returns the first byte produced by a dictionary [code].
  int _firstByte(Int32List prefixes, Uint8List suffixes, int code) {
    int current = code;
    while (current >= 256) {
      current = prefixes[current];
    }
    return current;
  }

  /// Reverses the horizontal differencing predictor in-place.
  void _undoHorizontalPredictor(Uint8List bytes, int rowBytes, int pixelBytes, int sampleBits, Endian endian) {
    if (sampleBits == 16) {
      final ByteData data = ByteData.sublistView(bytes);
      for (int rowOffset = 0; rowOffset < bytes.length; rowOffset += rowBytes) {
        for (int offset = rowOffset + pixelBytes; offset + 1 < rowOffset + rowBytes; offset += 2) {
          final int previous = data.getUint16(offset - pixelBytes, endian);
          data.setUint16(offset, (data.getUint16(offset, endian) + previous) & 0xffff, endian);
        }
      }
      return;
    }
    for (int rowOffset = 0; rowOffset < bytes.length; rowOffset += rowBytes) {
      for (int offset = rowOffset + pixelBytes; offset < rowOffset + rowBytes; offset++) {
        bytes[offset] = (bytes[offset] + bytes[offset - pixelBytes]) & 0xff;
      }
    }
  }

  /// Expands packed samples into the selected native scalar representation.
  ///
  /// Palette indices keep their raw value; other narrow samples are scaled to
  /// the full eight-bit range so grayscale images retain their brightness.
  void _expandSamples(
    Uint8List packed,
    _TiffSampleBuffer samples,
    int destination,
    int rowCount,
    int rowBytes,
    int packedRowBytes,
    int sampleBits,
    int sampleRepresentation,
    Endian endian,
    bool paletteIndices,
  ) {
    if (sampleRepresentation == 3) {
      final ByteData data = ByteData.sublistView(packed);
      int target = destination;
      for (int row = 0; row < rowCount; row++) {
        int source = row * packedRowBytes;
        for (int sample = 0; sample < rowBytes; sample++) {
          samples.writeFloat(target++, data.getFloat32(source, endian));
          source += 4;
        }
      }
      return;
    }
    if (sampleBits == 8) {
      assert(samples.format == DecodedSampleFormat.uint8, 'Eight-bit TIFF samples always use byte storage');
      samples.bytes.setRange(destination, destination + rowCount * rowBytes, packed);
      return;
    }
    if (sampleBits == 16) {
      final ByteData data = ByteData.sublistView(packed);
      int target = destination;
      for (int row = 0; row < rowCount; row++) {
        int source = row * packedRowBytes;
        for (int sample = 0; sample < rowBytes; sample++) {
          samples.writeUnsigned(target++, data.getUint16(source, endian));
          source += 2;
        }
      }
      return;
    }
    final int maximum = (1 << sampleBits) - 1;
    int target = destination;
    for (int row = 0; row < rowCount; row++) {
      final int rowStart = row * packedRowBytes;
      for (int sample = 0; sample < rowBytes; sample++) {
        final int bitOffset = sample * sampleBits;
        final int value = (packed[rowStart + (bitOffset >>> 3)] >>> (8 - sampleBits - (bitOffset & 7))) & maximum;
        samples.writeUnsigned(
          target++,
          paletteIndices ? value : (value * 255 + (maximum >> 1)) ~/ maximum,
        );
      }
    }
  }

  /// Converts supported TIFF interpretations to native process-plus-alpha.
  _TiffRaster _convertToRaster(
    _TiffSampleBuffer samples, {
    required int width,
    required int height,
    required int orientation,
    required int samplesPerPixel,
    required int photometric,
    required List<int>? colorMap,
    required bool associatedAlpha,
  }) {
    final int pixelCount = width * height;
    final DecodedColorModel colorModel = photometric == 5 ? DecodedColorModel.cmyk : DecodedColorModel.rgb;
    final int processChannels = colorModel.processChannelCount;
    final int outputChannels = processChannels + 1;
    // The sample layout is fixed for a whole image, so it is validated once
    // instead of on every pixel.
    final bool hasAlphaSample = _validateSampleLayout(photometric, samplesPerPixel, colorMap);
    final int sourceProcessChannels = switch (photometric) {
      2 => 3,
      5 => 4,
      _ => 1,
    };
    final _TiffSampleBuffer output = _TiffSampleBuffer(
      pixelCount * outputChannels,
      samples.format,
    );

    // Grayscale, RGB and CMYK samples already carry their output meaning, so
    // they move as raw scalars rather than through normalized doubles.
    if (photometric != 0 && photometric != 3 && !associatedAlpha) {
      _copyProcessSamples(
        samples,
        output,
        pixelCount: pixelCount,
        samplesPerPixel: samplesPerPixel,
        outputChannels: outputChannels,
        processChannels: processChannels,
        sourceProcessChannels: sourceProcessChannels,
        broadcastsGray: photometric == 1,
        hasAlphaSample: hasAlphaSample,
      );
      return _TiffRaster(
        samples: output,
        colorModel: colorModel,
        width: width,
        height: height,
        orientation: orientation,
      );
    }

    final int paletteLength = photometric == 3 ? colorMap!.length ~/ 3 : 0;
    // Palette entries are always sixteen bits wide, whatever the index width.
    final int paletteShift = samples.format == DecodedSampleFormat.uint8 ? 8 : 0;
    final double paletteMaximum = photometric != 3
        ? 1
        : switch (samples.format) {
            DecodedSampleFormat.uint8 => 255,
            DecodedSampleFormat.uint16 => 65535,
            DecodedSampleFormat.float32 => throw const ImageCodecException(
              'A floating-point TIFF image cannot use a palette',
            ),
          };
    final Float64List process = Float64List(processChannels);
    for (int pixel = 0; pixel < pixelCount; pixel++) {
      final int source = pixel * samplesPerPixel;
      final int destination = pixel * outputChannels;
      if (photometric == 3) {
        final int paletteIndex = samples.unsignedAt(source);
        if (paletteIndex >= paletteLength) {
          throw const ImageCodecException('A TIFF palette index is out of range');
        }
        process[0] = (colorMap![paletteIndex] >>> paletteShift) / paletteMaximum;
        process[1] = (colorMap[paletteLength + paletteIndex] >>> paletteShift) / paletteMaximum;
        process[2] = (colorMap[paletteLength * 2 + paletteIndex] >>> paletteShift) / paletteMaximum;
      } else if (photometric == 0 || photometric == 1) {
        final double storedGray = samples.normalizedAt(source);
        final double gray = photometric == 0 ? 1 - storedGray : storedGray;
        process[0] = gray;
        process[1] = gray;
        process[2] = gray;
      } else {
        for (int channel = 0; channel < processChannels; channel++) {
          process[channel] = samples.normalizedAt(source + channel);
        }
      }
      final double alpha = hasAlphaSample ? samples.normalizedAt(source + sourceProcessChannels) : 1;
      if (associatedAlpha && alpha != 0 && alpha != 1) {
        for (int channel = 0; channel < processChannels; channel++) {
          process[channel] = process[channel] / alpha;
        }
      }
      for (int channel = 0; channel < processChannels; channel++) {
        output.writeNormalized(destination + channel, process[channel]);
      }
      output.writeNormalized(destination + processChannels, alpha);
    }
    return _TiffRaster(
      samples: output,
      colorModel: colorModel,
      width: width,
      height: height,
      orientation: orientation,
    );
  }

  /// Moves samples that already carry their output meaning, without rescaling.
  ///
  /// Byte samples get their own loop because they are by far the most common
  /// TIFF layout and gain from skipping the per-scalar representation switch.
  void _copyProcessSamples(
    _TiffSampleBuffer samples,
    _TiffSampleBuffer output, {
    required int pixelCount,
    required int samplesPerPixel,
    required int outputChannels,
    required int processChannels,
    required int sourceProcessChannels,
    required bool broadcastsGray,
    required bool hasAlphaSample,
  }) {
    if (samples.format == DecodedSampleFormat.uint8) {
      final Uint8List input = samples.bytes;
      final Uint8List result = output.bytes;
      for (int pixel = 0; pixel < pixelCount; pixel++) {
        final int source = pixel * samplesPerPixel;
        final int destination = pixel * outputChannels;
        if (broadcastsGray) {
          final int gray = input[source];
          result[destination] = gray;
          result[destination + 1] = gray;
          result[destination + 2] = gray;
        } else {
          for (int channel = 0; channel < processChannels; channel++) {
            result[destination + channel] = input[source + channel];
          }
        }
        result[destination + processChannels] = hasAlphaSample ? input[source + sourceProcessChannels] : 255;
      }
      return;
    }
    for (int pixel = 0; pixel < pixelCount; pixel++) {
      final int source = pixel * samplesPerPixel;
      final int destination = pixel * outputChannels;
      if (broadcastsGray) {
        output.copyScalar(samples, source, destination);
        output.copyScalar(samples, source, destination + 1);
        output.copyScalar(samples, source, destination + 2);
      } else {
        for (int channel = 0; channel < processChannels; channel++) {
          output.copyScalar(samples, source + channel, destination + channel);
        }
      }
      if (hasAlphaSample) {
        output.copyScalar(samples, source + sourceProcessChannels, destination + processChannels);
      } else {
        output.writeOpaque(destination + processChannels);
      }
    }
  }

  /// Validates the sample layout and reports whether an alpha sample follows.
  bool _validateSampleLayout(int photometric, int samplesPerPixel, List<int>? colorMap) {
    switch (photometric) {
      case 0:
      case 1:
        if (samplesPerPixel != 1 && samplesPerPixel != 2) {
          throw const ImageCodecException('Invalid grayscale TIFF sample count');
        }
        return samplesPerPixel == 2;
      case 2:
        if (samplesPerPixel != 3 && samplesPerPixel != 4) {
          throw const ImageCodecException('Invalid RGB TIFF sample count');
        }
        return samplesPerPixel == 4;
      case 3:
        if (samplesPerPixel != 1 || colorMap == null || colorMap.length % 3 != 0) {
          throw const ImageCodecException('Invalid palette TIFF data');
        }
        return false;
      case 5:
        if (samplesPerPixel != 4 && samplesPerPixel != 5) {
          throw const ImageCodecException('Invalid CMYK TIFF sample count');
        }
        return samplesPerPixel == 5;
      default:
        throw ImageCodecException('Unsupported TIFF photometric interpretation: $photometric');
    }
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

/// Stores decoded TIFF scalars in their output-native byte representation.
final class _TiffSampleBuffer {
  /// Scalar representation shared by every sample.
  final DecodedSampleFormat format;

  /// Mutable little-endian sample storage.
  final Uint8List bytes;

  /// Typed accessor over [bytes].
  late final ByteData _data = ByteData.sublistView(bytes);

  /// Allocates [length] scalar values.
  _TiffSampleBuffer(int length, this.format) : bytes = Uint8List(length * format.bytesPerChannel);

  /// Stores one unsigned sample without rescaling it.
  void writeUnsigned(int index, int value) {
    final int offset = index * format.bytesPerChannel;
    switch (format) {
      case DecodedSampleFormat.uint8:
        bytes[offset] = value;
      case DecodedSampleFormat.uint16:
        _data.setUint16(offset, value, Endian.little);
      case DecodedSampleFormat.float32:
        throw const ImageCodecException(
          'An integer TIFF sample cannot be written as float implicitly',
        );
    }
  }

  /// Stores one IEEE-754 sample without normalizing it.
  void writeFloat(int index, double value) {
    if (format != DecodedSampleFormat.float32) {
      throw const ImageCodecException(
        'A floating-point TIFF sample needs float output storage',
      );
    }
    _data.setFloat32(
      index * format.bytesPerChannel,
      value.isFinite ? value : 0,
      Endian.little,
    );
  }

  /// Copies one scalar from [source], which must share this representation.
  void copyScalar(_TiffSampleBuffer source, int sourceIndex, int index) {
    final int channelBytes = format.bytesPerChannel;
    final int from = sourceIndex * channelBytes;
    final int to = index * channelBytes;
    for (int offset = 0; offset < channelBytes; offset++) {
      bytes[to + offset] = source.bytes[from + offset];
    }
  }

  /// Stores the fully opaque value of this representation.
  void writeOpaque(int index) {
    final int offset = index * format.bytesPerChannel;
    switch (format) {
      case DecodedSampleFormat.uint8:
        bytes[offset] = 255;
      case DecodedSampleFormat.uint16:
        _data.setUint16(offset, 65535, Endian.little);
      case DecodedSampleFormat.float32:
        _data.setFloat32(offset, 1, Endian.little);
    }
  }

  /// Reads an integer sample for palette lookup.
  int unsignedAt(int index) {
    final int offset = index * format.bytesPerChannel;
    return switch (format) {
      DecodedSampleFormat.uint8 => bytes[offset],
      DecodedSampleFormat.uint16 => _data.getUint16(offset, Endian.little),
      DecodedSampleFormat.float32 => throw const ImageCodecException(
        'A floating-point TIFF sample cannot index a palette',
      ),
    };
  }

  /// Reads one unsigned-normalized or floating-point scalar.
  double normalizedAt(int index) {
    final int offset = index * format.bytesPerChannel;
    return switch (format) {
      DecodedSampleFormat.uint8 => bytes[offset] / 255,
      DecodedSampleFormat.uint16 => _data.getUint16(offset, Endian.little) / 65535,
      DecodedSampleFormat.float32 => _data.getFloat32(offset, Endian.little),
    };
  }

  /// Stores one normalized value, preserving finite float values outside SDR.
  void writeNormalized(int index, double value) {
    final double finite = value.isFinite ? value : 0;
    final int offset = index * format.bytesPerChannel;
    switch (format) {
      case DecodedSampleFormat.uint8:
        bytes[offset] = (finite.clamp(0, 1) * 255).round();
      case DecodedSampleFormat.uint16:
        _data.setUint16(
          offset,
          (finite.clamp(0, 1) * 65535).round(),
          Endian.little,
        );
      case DecodedSampleFormat.float32:
        _data.setFloat32(offset, finite, Endian.little);
    }
  }
}

/// Holds decoded TIFF samples until they reach their final container.
///
/// Orientation is deferred so that a caller still owning the buffer can hand
/// it to an [Image] instead of copying an already immutable [DecodedImage].
final class _TiffRaster {
  /// Decoded process-plus-alpha samples in stream order.
  final _TiffSampleBuffer samples;

  /// Process colour model represented by [samples].
  final DecodedColorModel colorModel;

  /// Width before applying [orientation].
  final int width;

  /// Height before applying [orientation].
  final int height;

  /// Encoded display orientation, from one to eight.
  final int orientation;

  /// Creates one decoded but still unoriented TIFF raster.
  const _TiffRaster({
    required this.samples,
    required this.colorModel,
    required this.width,
    required this.height,
    required this.orientation,
  });

  /// Width after applying [orientation].
  int get orientedWidth => orientation >= 5 ? height : width;

  /// Height after applying [orientation].
  int get orientedHeight => orientation >= 5 ? width : height;

  /// Returns oriented samples, reusing the buffer when no pixel moves.
  Uint8List orientedBytes() => orientation == 1
      ? samples.bytes
      : DecodedImage.orientPixels(
          samples.bytes,
          width: width,
          height: height,
          bytesPerPixel: (colorModel.processChannelCount + 1) * samples.format.bytesPerChannel,
          orientation: orientation,
        );

  /// Wraps the oriented samples as an immutable decoded raster.
  DecodedImage toDecodedImage() => DecodedImage(
    width: orientedWidth,
    height: orientedHeight,
    colorModel: colorModel,
    sampleFormat: samples.format,
    bytes: orientedBytes(),
    copy: false,
  );
}
