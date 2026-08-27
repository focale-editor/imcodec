part of '../png.dart';

/// Decodes standard and Adam7-interlaced PNG pixels synchronously.
final class PngDecoder extends RasterDecoder {
  /// Eight-byte PNG file signature.
  static const List<int> _signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

  /// Horizontal starting coordinates for the seven Adam7 passes.
  static const List<int> _adam7StartX = [0, 4, 0, 2, 0, 1, 0];

  /// Vertical starting coordinates for the seven Adam7 passes.
  static const List<int> _adam7StartY = [0, 0, 4, 0, 2, 0, 1];

  /// Horizontal strides for the seven Adam7 passes.
  static const List<int> _adam7StepX = [8, 8, 4, 4, 2, 2, 1];

  /// Vertical strides for the seven Adam7 passes.
  static const List<int> _adam7StepY = [8, 8, 8, 4, 4, 2, 2];

  /// Creates a PNG decoder.
  const PngDecoder();

  /// Decodes the default PNG image to straight-alpha RGBA pixels.
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    _validateSignature(bytes);
    final ByteData byteData = ByteData.sublistView(bytes);
    final BytesBuilder compressedData = BytesBuilder(copy: false);
    _PngHeader? header;
    List<_PngColor>? palette;
    List<int>? paletteAlpha;
    int? transparentGray;
    _PngTransparentColor? transparentColor;
    bool hasImageData = false;
    bool imageDataEnded = false;
    bool hasEnd = false;
    int position = _signature.length;

    while (position < bytes.length) {
      if (bytes.length - position < 12) {
        throw const ImageCodecException('The PNG chunk header is truncated');
      }
      final int dataLength = byteData.getUint32(position, Endian.big);
      final int typeOffset = position + 4;
      final int dataOffset = typeOffset + 4;
      final int checksumOffset = dataOffset + dataLength;
      if (dataLength > bytes.length - dataOffset - 4) {
        throw const ImageCodecException('The PNG chunk data is truncated');
      }
      final Uint8List type = Uint8List.sublistView(bytes, typeOffset, dataOffset);
      final Uint8List data = Uint8List.sublistView(bytes, dataOffset, checksumOffset);
      final int expectedChecksum = byteData.getUint32(checksumOffset, Endian.big);
      if (_PngChecksum.compute(type, data) != expectedChecksum) {
        throw ImageCodecException('Invalid PNG checksum for the ${String.fromCharCodes(type)} chunk');
      }
      final String chunkType = String.fromCharCodes(type);

      switch (chunkType) {
        case 'IHDR':
          if (header != null || position != _signature.length) {
            throw const ImageCodecException('PNG must contain exactly one leading IHDR chunk');
          }
          header = _readHeader(data);
          _checkDimensions(header.width, header.height, maxPixels: maxPixels);
        case 'PLTE':
          if (header == null || hasImageData || palette != null) {
            throw const ImageCodecException('PNG palette chunk is out of order');
          }
          palette = _readPalette(data, header);
        case 'tRNS':
          if (header == null || hasImageData || paletteAlpha != null || transparentGray != null || transparentColor != null) {
            throw const ImageCodecException('PNG transparency chunk is out of order');
          }
          switch (header.colorType) {
            case 0:
              if (data.length != 2) {
                throw const ImageCodecException('Grayscale PNG transparency must contain one sample');
              }
              transparentGray = ByteData.sublistView(data).getUint16(0, Endian.big);
            case 2:
              if (data.length != 6) {
                throw const ImageCodecException('True-color PNG transparency must contain three samples');
              }
              final ByteData transparency = ByteData.sublistView(data);
              transparentColor = _PngTransparentColor(
                red: transparency.getUint16(0, Endian.big),
                green: transparency.getUint16(2, Endian.big),
                blue: transparency.getUint16(4, Endian.big),
              );
            case 3:
              if (palette == null || data.length > palette.length) {
                throw const ImageCodecException('Indexed PNG transparency requires a matching palette');
              }
              paletteAlpha = List<int>.unmodifiable(data);
            case 4 || 6:
              throw const ImageCodecException('PNG transparency chunks are invalid when pixels already contain alpha');
            default:
              throw const ImageCodecException('Unsupported PNG color type');
          }
        case 'IDAT':
          if (header == null || imageDataEnded) {
            throw const ImageCodecException('PNG image-data chunks must be consecutive and follow IHDR');
          }
          if (header.colorType == 3 && palette == null) {
            throw const ImageCodecException('Indexed PNG data requires a palette');
          }
          hasImageData = true;
          compressedData.add(data);
        case 'IEND':
          if (header == null || !hasImageData || data.isNotEmpty) {
            throw const ImageCodecException('Invalid PNG end chunk');
          }
          hasEnd = true;
        default:
          if (hasImageData) {
            imageDataEnded = true;
          }
          if ((type[0] & 0x20) == 0) {
            throw ImageCodecException('Unsupported critical PNG chunk: $chunkType');
          }
      }

      position = checksumOffset + 4;
      if (hasEnd) {
        // Trailing bytes after IEND are ignored, matching common decoders:
        // some writers pad the file and the image itself is still complete.
        break;
      }
    }

    if (header == null || !hasImageData || !hasEnd) {
      throw const ImageCodecException('PNG is missing required image chunks');
    }
    final int expectedLength = _expectedInflatedLength(header);
    final Uint8List inflated = const ZlibCodec().decode(
      compressedData.takeBytes(),
      maxOutputBytes: expectedLength,
    );
    if (inflated.length != expectedLength) {
      throw ImageCodecException('Expected $expectedLength inflated PNG bytes, received ${inflated.length}');
    }
    final Uint8List rgba = Uint8List(header.width * header.height * 4);
    _decodePasses(
      inflated,
      rgba,
      header,
      palette,
      paletteAlpha,
      transparentGray,
      transparentColor,
    );
    return Image.fromRgba(width: header.width, height: header.height, bytes: rgba, copy: false);
  }

  /// Verifies the fixed PNG signature.
  void _validateSignature(Uint8List bytes) {
    if (bytes.length < _signature.length) {
      throw const ImageCodecException('The PNG signature is truncated');
    }
    for (int index = 0; index < _signature.length; index++) {
      if (bytes[index] != _signature[index]) {
        throw const ImageCodecException('Invalid PNG signature');
      }
    }
  }

  /// Reads and validates the fixed-size image header.
  _PngHeader _readHeader(Uint8List data) {
    if (data.length != 13) {
      throw const ImageCodecException('PNG IHDR must contain exactly 13 bytes');
    }
    final ByteData header = ByteData.sublistView(data);
    final int width = header.getUint32(0, Endian.big);
    final int height = header.getUint32(4, Endian.big);
    final int bitDepth = header.getUint8(8);
    final int colorType = header.getUint8(9);
    final Set<int>? allowedDepths = switch (colorType) {
      0 => const {1, 2, 4, 8, 16},
      2 => const {8, 16},
      3 => const {1, 2, 4, 8},
      4 => const {8, 16},
      6 => const {8, 16},
      _ => null,
    };
    if (allowedDepths == null || !allowedDepths.contains(bitDepth)) {
      throw ImageCodecException('Unsupported PNG color type $colorType at $bitDepth bits per sample');
    }
    if (header.getUint8(10) != 0 || header.getUint8(11) != 0) {
      throw const ImageCodecException('Unsupported PNG compression or filter method');
    }
    final int interlaceMethod = header.getUint8(12);
    if (interlaceMethod != 0 && interlaceMethod != 1) {
      throw ImageCodecException('Unsupported PNG interlace method: $interlaceMethod');
    }
    return _PngHeader(
      width: width,
      height: height,
      bitDepth: bitDepth,
      colorType: colorType,
      interlaced: interlaceMethod == 1,
    );
  }

  /// Reads an RGB palette and checks its size against the bit depth.
  List<_PngColor> _readPalette(Uint8List data, _PngHeader header) {
    if (header.colorType == 0 || header.colorType == 4 || data.isEmpty || data.length % 3 != 0 || data.length > 768) {
      throw const ImageCodecException('Invalid PNG palette');
    }
    final int colorCount = data.length ~/ 3;
    if (header.colorType == 3 && colorCount > 1 << header.bitDepth) {
      throw const ImageCodecException('PNG palette has more colors than its bit depth can address');
    }
    return List<_PngColor>.generate(
      colorCount,
      (index) {
        final int offset = index * 3;
        return _PngColor(red: data[offset], green: data[offset + 1], blue: data[offset + 2]);
      },
      growable: false,
    );
  }

  /// Rejects dimensions before any decoded pixel allocation.
  void _checkDimensions(int width, int height, {required int maxPixels}) {
    if (width < 1 || height < 1 || width > 0x7fffffff || height > 0x7fffffff) {
      throw const ImageCodecException('PNG dimensions must be between 1 and 2147483647 pixels');
    }
    final int pixelCount = width * height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
  }

  /// Calculates the exact number of filtered bytes described by the header.
  int _expectedInflatedLength(_PngHeader header) {
    int length = 0;
    for (int pass = 0; pass < (header.interlaced ? 7 : 1); pass++) {
      final int width = header.interlaced ? _passSize(header.width, _adam7StartX[pass], _adam7StepX[pass]) : header.width;
      final int height = header.interlaced ? _passSize(header.height, _adam7StartY[pass], _adam7StepY[pass]) : header.height;
      if (width > 0 && height > 0) {
        length += height * (1 + (width * header.bitsPerPixel + 7) ~/ 8);
      }
    }
    return length;
  }

  /// Unfilters every pass and places its samples in the final canvas.
  void _decodePasses(
    Uint8List inflated,
    Uint8List rgba,
    _PngHeader header,
    List<_PngColor>? palette,
    List<int>? paletteAlpha,
    int? transparentGray,
    _PngTransparentColor? transparentColor,
  ) {
    int sourceOffset = 0;
    for (int pass = 0; pass < (header.interlaced ? 7 : 1); pass++) {
      final int startX = header.interlaced ? _adam7StartX[pass] : 0;
      final int startY = header.interlaced ? _adam7StartY[pass] : 0;
      final int stepX = header.interlaced ? _adam7StepX[pass] : 1;
      final int stepY = header.interlaced ? _adam7StepY[pass] : 1;
      final int passWidth = _passSize(header.width, startX, stepX);
      final int passHeight = _passSize(header.height, startY, stepY);
      if (passWidth == 0 || passHeight == 0) {
        continue;
      }
      final int rowLength = (passWidth * header.bitsPerPixel + 7) ~/ 8;
      final int predictorBytes = ((header.bitsPerPixel + 7) ~/ 8).clamp(1, 8);
      Uint8List previousRow = Uint8List(rowLength);
      Uint8List row = Uint8List(rowLength);
      for (int passY = 0; passY < passHeight; passY++) {
        final int filter = inflated[sourceOffset++];
        _unfilterRow(inflated, sourceOffset, row, previousRow, rowLength, predictorBytes, filter);
        sourceOffset += rowLength;
        _writeRow(
          row,
          rgba,
          header,
          passWidth,
          startX,
          startY + passY * stepY,
          stepX,
          palette,
          paletteAlpha,
          transparentGray,
          transparentColor,
        );
        final Uint8List swap = previousRow;
        previousRow = row;
        row = swap;
      }
    }
    if (sourceOffset != inflated.length) {
      throw const ImageCodecException('PNG decompression produced unexpected trailing bytes');
    }
  }

  /// Reverses one row filter, using a dedicated loop for each filter type.
  void _unfilterRow(
    Uint8List inflated,
    int sourceOffset,
    Uint8List row,
    Uint8List previousRow,
    int rowLength,
    int predictorBytes,
    int filter,
  ) {
    switch (filter) {
      case 0:
        row.setRange(0, rowLength, inflated, sourceOffset);
      case 1:
        final int leading = predictorBytes < rowLength ? predictorBytes : rowLength;
        row.setRange(0, leading, inflated, sourceOffset);
        for (int byte = predictorBytes; byte < rowLength; byte++) {
          row[byte] = (inflated[sourceOffset + byte] + row[byte - predictorBytes]) & 0xff;
        }
      case 2:
        for (int byte = 0; byte < rowLength; byte++) {
          row[byte] = (inflated[sourceOffset + byte] + previousRow[byte]) & 0xff;
        }
      case 3:
        for (int byte = 0; byte < predictorBytes && byte < rowLength; byte++) {
          row[byte] = (inflated[sourceOffset + byte] + (previousRow[byte] >> 1)) & 0xff;
        }
        for (int byte = predictorBytes; byte < rowLength; byte++) {
          row[byte] = (inflated[sourceOffset + byte] + ((row[byte - predictorBytes] + previousRow[byte]) >> 1)) & 0xff;
        }
      case 4:
        for (int byte = 0; byte < predictorBytes && byte < rowLength; byte++) {
          row[byte] = (inflated[sourceOffset + byte] + previousRow[byte]) & 0xff;
        }
        for (int byte = predictorBytes; byte < rowLength; byte++) {
          row[byte] = (inflated[sourceOffset + byte] + _paeth(row[byte - predictorBytes], previousRow[byte], previousRow[byte - predictorBytes])) & 0xff;
        }
      default:
        throw ImageCodecException('Unsupported PNG row filter: $filter');
    }
  }

  /// Converts one unfiltered scanline to RGBA pixels.
  void _writeRow(
    Uint8List row,
    Uint8List rgba,
    _PngHeader header,
    int passWidth,
    int startX,
    int destinationY,
    int stepX,
    List<_PngColor>? palette,
    List<int>? paletteAlpha,
    int? transparentGray,
    _PngTransparentColor? transparentColor,
  ) {
    if (header.bitDepth == 8 && stepX == 1 && startX == 0) {
      final int destination = destinationY * header.width * 4;
      if (header.colorType == 6) {
        rgba.setRange(destination, destination + passWidth * 4, row);
        return;
      }
      if (header.colorType == 2 && transparentColor == null) {
        int source = 0;
        for (int offset = destination; offset < destination + passWidth * 4; offset += 4) {
          rgba[offset] = row[source];
          rgba[offset + 1] = row[source + 1];
          rgba[offset + 2] = row[source + 2];
          rgba[offset + 3] = 255;
          source += 3;
        }
        return;
      }
    }
    int sample = 0;
    for (int passX = 0; passX < passWidth; passX++) {
      final int destinationX = startX + passX * stepX;
      final int destination = (destinationY * header.width + destinationX) * 4;
      switch (header.colorType) {
        case 0:
          final int graySample = _readSample(row, sample++, header.bitDepth);
          final int gray = _scaleSample(graySample, header.bitDepth);
          rgba[destination] = gray;
          rgba[destination + 1] = gray;
          rgba[destination + 2] = gray;
          rgba[destination + 3] = graySample == transparentGray ? 0 : 255;
        case 2:
          final int redSample = _readSample(row, sample++, header.bitDepth);
          final int greenSample = _readSample(row, sample++, header.bitDepth);
          final int blueSample = _readSample(row, sample++, header.bitDepth);
          rgba[destination] = _scaleSample(redSample, header.bitDepth);
          rgba[destination + 1] = _scaleSample(greenSample, header.bitDepth);
          rgba[destination + 2] = _scaleSample(blueSample, header.bitDepth);
          rgba[destination + 3] = transparentColor != null && transparentColor.matches(redSample, greenSample, blueSample) ? 0 : 255;
        case 3:
          final int paletteIndex = _readSample(row, sample++, header.bitDepth);
          if (palette == null || paletteIndex >= palette.length) {
            throw const ImageCodecException('PNG pixel references a missing palette entry');
          }
          final _PngColor color = palette[paletteIndex];
          rgba[destination] = color.red;
          rgba[destination + 1] = color.green;
          rgba[destination + 2] = color.blue;
          rgba[destination + 3] = paletteAlpha != null && paletteIndex < paletteAlpha.length ? paletteAlpha[paletteIndex] : 255;
        case 4:
          final int gray = _scaleSample(_readSample(row, sample++, header.bitDepth), header.bitDepth);
          rgba[destination] = gray;
          rgba[destination + 1] = gray;
          rgba[destination + 2] = gray;
          rgba[destination + 3] = _scaleSample(_readSample(row, sample++, header.bitDepth), header.bitDepth);
        case 6:
          rgba[destination] = _scaleSample(_readSample(row, sample++, header.bitDepth), header.bitDepth);
          rgba[destination + 1] = _scaleSample(_readSample(row, sample++, header.bitDepth), header.bitDepth);
          rgba[destination + 2] = _scaleSample(_readSample(row, sample++, header.bitDepth), header.bitDepth);
          rgba[destination + 3] = _scaleSample(_readSample(row, sample++, header.bitDepth), header.bitDepth);
        default:
          throw const ImageCodecException('Unsupported PNG color type');
      }
    }
  }

  /// Reads one packed sample at [sampleIndex].
  int _readSample(Uint8List row, int sampleIndex, int bitDepth) {
    if (bitDepth == 8) {
      return row[sampleIndex];
    }
    if (bitDepth == 16) {
      final int offset = sampleIndex * 2;
      return (row[offset] << 8) | row[offset + 1];
    }
    final int bitOffset = sampleIndex * bitDepth;
    final int shift = 8 - bitDepth - (bitOffset & 7);
    return (row[bitOffset >>> 3] >>> shift) & ((1 << bitDepth) - 1);
  }

  /// Scales a sample of [bitDepth] to eight bits with rounding.
  int _scaleSample(int sample, int bitDepth) {
    if (bitDepth == 8) {
      return sample;
    }
    final int maximum = (1 << bitDepth) - 1;
    return (sample * 255 + (maximum >> 1)) ~/ maximum;
  }

  /// Returns the number of samples visited by a strided pass.
  int _passSize(int size, int start, int step) => size <= start ? 0 : (size - start + step - 1) ~/ step;

  /// Predicts one byte from its left, upper, and upper-left neighbors.
  int _paeth(int left, int above, int upperLeft) {
    final int prediction = left + above - upperLeft;
    final int leftDistance = (prediction - left).abs();
    final int aboveDistance = (prediction - above).abs();
    final int upperLeftDistance = (prediction - upperLeft).abs();
    if (leftDistance <= aboveDistance && leftDistance <= upperLeftDistance) {
      return left;
    }
    return aboveDistance <= upperLeftDistance ? above : upperLeft;
  }
}

/// Stores the structural fields needed to decode PNG pixels.
final class _PngHeader {
  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Number of bits used by each channel sample.
  final int bitDepth;

  /// PNG channel-layout identifier.
  final int colorType;

  /// Whether samples use the seven-pass Adam7 layout.
  final bool interlaced;

  /// Creates a validated header description.
  const _PngHeader({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.interlaced,
  });

  /// Number of channels stored for each pixel.
  int get channelCount => switch (colorType) {
    0 || 3 => 1,
    2 => 3,
    4 => 2,
    6 => 4,
    _ => throw StateError('Unexpected PNG color type'),
  };

  /// Number of packed bits stored for each pixel.
  int get bitsPerPixel => channelCount * bitDepth;
}

/// Stores one palette entry.
final class _PngColor {
  /// Red channel.
  final int red;

  /// Green channel.
  final int green;

  /// Blue channel.
  final int blue;

  /// Creates an opaque palette color.
  const _PngColor({
    required this.red,
    required this.green,
    required this.blue,
  });
}

/// Stores the exact transparent sample tuple for true-color PNG data.
final class _PngTransparentColor {
  /// Red sample.
  final int red;

  /// Green sample.
  final int green;

  /// Blue sample.
  final int blue;

  /// Creates a transparent sample tuple.
  const _PngTransparentColor({
    required this.red,
    required this.green,
    required this.blue,
  });

  /// Reports whether a decoded sample tuple is transparent.
  bool matches(int candidateRed, int candidateGreen, int candidateBlue) => red == candidateRed && green == candidateGreen && blue == candidateBlue;
}
