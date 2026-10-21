part of '../tiff.dart';

/// Compression methods available when encoding TIFF images.
enum TiffCompression {
  /// Stores pixel bytes without compression.
  none(value: 1),

  /// Uses the byte-oriented PackBits run-length encoding.
  packBits(value: 32773);

  /// TIFF compression tag value.
  final int value;

  /// Creates a TIFF compression option.
  const TiffCompression({
    required this.value,
  });
}

/// Encodes straight RGBA pixels as baseline TIFF data.
final class TiffEncoder extends RasterEncoder<TiffEncodeOptions> {
  /// Number of directory entries emitted by this encoder.
  static const int _entryCount = 15;

  /// Largest number of literal or repeated bytes in one PackBits packet.
  static const int _packBitsPacketLimit = 128;

  /// Creates a baseline TIFF encoder.
  const TiffEncoder({
    TiffEncodeOptions defaultOptions = const TiffEncodeOptions(),
  }) : super(
         defaultEncodeOptions: defaultOptions,
       );

  /// Encodes [image] as chunky, eight-bit RGBA TIFF data in either byte order.
  @override
  Uint8List encodeWithOptions(Image image, TiffEncodeOptions options) {
    final Endian endian = options.byteOrder;
    final TiffPhotoshopData? photoshop = options.photoshopData;
    if (photoshop?.imageSourceData != null && photoshop!.byteOrder != endian) {
      throw const ImageCodecException('Photoshop layer data must match the TIFF output byte order; convert it with PsdKit first');
    }
    final double density = options.pixelsPerInch ?? 72;
    if (!density.isFinite || density <= 0) {
      throw ArgumentError.value(
        density,
        'pixelsPerInch',
        'Pixel density must be finite and positive',
      );
    }
    const int resolutionDenominator = 1000;
    final int resolutionNumerator = (density * resolutionDenominator).round();
    if (resolutionNumerator > 0xffffffff) {
      throw ArgumentError.value(
        density,
        'pixelsPerInch',
        'TIFF pixel density exceeds the format limit',
      );
    }
    final int rowBytes = image.width * 4;
    final Uint8List encodedPixels = switch (options.compression) {
      TiffCompression.none => image.bytes,
      TiffCompression.packBits => _encodePackBits(image.bytes, rowBytes),
    };
    const int firstIfdOffset = 8;
    final Map<int, Uint8List> payloads = {
      if (photoshop?.imageResources != null) 34377: photoshop!.imageResources!,
      if (options.iccProfile != null) 34675: options.iccProfile!,
      if (photoshop?.imageSourceData != null) 37724: photoshop!.imageSourceData!,
    };
    final int entryCount = _entryCount + payloads.length;
    final int ifdSize = 2 + entryCount * 12 + 4;
    final int bitsPerSampleOffset = firstIfdOffset + ifdSize;
    const int bitsPerSampleSize = 8;
    final int resolutionOffset = bitsPerSampleOffset + bitsPerSampleSize;
    const int resolutionSize = 16;
    final Map<int, int> offsets = {};
    int pixelOffset = resolutionOffset + resolutionSize;
    for (final MapEntry<int, Uint8List> payload in payloads.entries) {
      offsets[payload.key] = pixelOffset;
      pixelOffset = (pixelOffset + payload.value.length + 1) & ~1;
    }
    final ByteData data = ByteData(pixelOffset + encodedPixels.length);

    data
      ..setUint8(0, endian == Endian.little ? 0x49 : 0x4d)
      ..setUint8(1, endian == Endian.little ? 0x49 : 0x4d)
      ..setUint16(2, 42, endian)
      ..setUint32(4, firstIfdOffset, endian)
      ..setUint16(firstIfdOffset, entryCount, endian);

    // Entries must stay sorted by ascending tag number.
    int entryOffset = firstIfdOffset + 2;
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 256, type: 4, count: 1, value: image.width);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 257, type: 4, count: 1, value: image.height);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 258, type: 3, count: 4, value: bitsPerSampleOffset);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 259, type: 3, count: 1, value: options.compression.value);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 262, type: 3, count: 1, value: 2);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 273, type: 4, count: 1, value: pixelOffset);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 274, type: 3, count: 1, value: 1);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 277, type: 3, count: 1, value: 4);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 278, type: 4, count: 1, value: image.height);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 279, type: 4, count: 1, value: encodedPixels.length);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 282, type: 5, count: 1, value: resolutionOffset);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 283, type: 5, count: 1, value: resolutionOffset + 8);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 284, type: 3, count: 1, value: 1);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 296, type: 3, count: 1, value: 2);
    entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: 338, type: 3, count: 1, value: 2);
    for (final MapEntry<int, Uint8List> payload in payloads.entries) {
      final Uint8List bytes = payload.value;
      entryOffset = _writeEntry(data, entryOffset, endian: endian, tag: payload.key, type: 7, count: bytes.length, value: bytes.length <= 4 ? 0 : offsets[payload.key]!);
      final int destination = bytes.length <= 4 ? entryOffset - 4 : offsets[payload.key]!;
      data.buffer.asUint8List().setRange(destination, destination + bytes.length, bytes);
    }
    data.setUint32(entryOffset, 0, endian);
    for (int index = 0; index < 4; index++) {
      data.setUint16(bitsPerSampleOffset + index * 2, 8, endian);
    }
    for (int index = 0; index < 2; index++) {
      data
        ..setUint32(
          resolutionOffset + index * 8,
          resolutionNumerator,
          endian,
        )
        ..setUint32(
          resolutionOffset + index * 8 + 4,
          resolutionDenominator,
          endian,
        );
    }
    data.buffer.asUint8List().setRange(pixelOffset, pixelOffset + encodedPixels.length, encodedPixels);
    return data.buffer.asUint8List();
  }

  /// Writes one image-file-directory entry in the selected byte order.
  int _writeEntry(
    ByteData data,
    int offset, {
    required Endian endian,
    required int tag,
    required int type,
    required int count,
    required int value,
  }) {
    data
      ..setUint16(offset, tag, endian)
      ..setUint16(offset + 2, type, endian)
      ..setUint32(offset + 4, count, endian);
    if (type == 3 && count == 1) {
      data
        ..setUint16(offset + 8, value, endian)
        ..setUint16(offset + 10, 0, endian);
    } else {
      data.setUint32(offset + 8, value, endian);
    }
    return offset + 12;
  }

  /// Compresses [input] using TIFF PackBits packets, one row at a time.
  /// The TIFF specification requires every row to be packed independently, so
  /// no packet may span a row boundary.
  Uint8List _encodePackBits(Uint8List input, int rowBytes) {
    final BytesBuilder output = BytesBuilder(copy: false);
    for (int rowStart = 0; rowStart < input.length; rowStart += rowBytes) {
      _encodePackBitsRow(output, input, rowStart, rowStart + rowBytes);
    }
    return output.takeBytes();
  }

  /// Compresses the bytes of one row into literal and repeat packets.
  void _encodePackBitsRow(BytesBuilder output, Uint8List input, int start, int end) {
    int position = start;
    while (position < end) {
      final int runLength = _runLength(input, position, end);
      if (runLength >= 3) {
        output.add([257 - runLength, input[position]]);
        position += runLength;
        continue;
      }

      // Accumulate bytes that do not start a worthwhile run, without ever
      // letting the literal packet exceed the PackBits packet limit.
      final int literalStart = position;
      position += runLength;
      while (position < end && position - literalStart < _packBitsPacketLimit) {
        final int nextRunLength = _runLength(input, position, end);
        if (nextRunLength >= 3 || position - literalStart + nextRunLength > _packBitsPacketLimit) {
          break;
        }
        position += nextRunLength;
      }
      output
        ..add([position - literalStart - 1])
        ..add(Uint8List.sublistView(input, literalStart, position));
    }
  }

  /// Counts equal consecutive bytes from [position], capped at one packet.
  int _runLength(Uint8List input, int position, int end) {
    final int packetEnd = position + _packBitsPacketLimit;
    final int limit = packetEnd < end ? packetEnd : end;
    final int value = input[position];
    int next = position + 1;
    while (next < limit && input[next] == value) {
      next++;
    }
    return next - position;
  }
}

/// Options for the TIFF encoder.
final class TiffEncodeOptions extends RasterEncodeOptions {
  /// Compression used when encoding pixel strips.
  final TiffCompression compression;

  /// Optional square pixel density, defaulting to the legacy 72 DPI output.
  final double? pixelsPerInch;

  /// ICC payload describing the input RGB samples, embedded without conversion.
  final Uint8List? iccProfile;

  /// Byte order of the TIFF container and any embedded Photoshop layer payload.
  final Endian byteOrder;

  /// Optional Photoshop layer and resource tags, preserved without rasterization.
  final TiffPhotoshopData? photoshopData;

  /// Creates a TIFF encode with the default options.
  const TiffEncodeOptions({
    this.compression = TiffCompression.packBits,
    this.pixelsPerInch,
    this.iccProfile,
    this.byteOrder = Endian.little,
    this.photoshopData,
  });
}
