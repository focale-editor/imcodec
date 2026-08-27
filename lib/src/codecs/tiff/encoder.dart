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
final class TiffEncoder extends RasterEncoder {
  /// Number of directory entries emitted by this encoder.
  static const int _entryCount = 15;

  /// Largest number of literal or repeated bytes in one PackBits packet.
  static const int _packBitsPacketLimit = 128;

  /// Compression used when encoding pixel strips.
  final TiffCompression compression;

  /// Creates a baseline TIFF encoder.
  const TiffEncoder({
    this.compression = TiffCompression.packBits,
  });

  /// Encodes [image] as a little-endian, chunky, eight-bit RGBA TIFF image.
  @override
  Uint8List encode(Image image) {
    final int rowBytes = image.width * 4;
    final Uint8List encodedPixels = switch (compression) {
      TiffCompression.none => image.bytes,
      TiffCompression.packBits => _encodePackBits(image.bytes, rowBytes),
    };
    const int firstIfdOffset = 8;
    const int ifdSize = 2 + _entryCount * 12 + 4;
    const int bitsPerSampleOffset = firstIfdOffset + ifdSize;
    const int bitsPerSampleSize = 8;
    const int resolutionOffset = bitsPerSampleOffset + bitsPerSampleSize;
    const int resolutionSize = 16;
    const int pixelOffset = resolutionOffset + resolutionSize;
    final ByteData data = ByteData(pixelOffset + encodedPixels.length);

    data
      ..setUint8(0, 0x49)
      ..setUint8(1, 0x49)
      ..setUint16(2, 42, Endian.little)
      ..setUint32(4, firstIfdOffset, Endian.little)
      ..setUint16(firstIfdOffset, _entryCount, Endian.little);

    // Entries must stay sorted by ascending tag number.
    int entryOffset = firstIfdOffset + 2;
    entryOffset = _writeEntry(data, entryOffset, tag: 256, type: 4, count: 1, value: image.width);
    entryOffset = _writeEntry(data, entryOffset, tag: 257, type: 4, count: 1, value: image.height);
    entryOffset = _writeEntry(data, entryOffset, tag: 258, type: 3, count: 4, value: bitsPerSampleOffset);
    entryOffset = _writeEntry(data, entryOffset, tag: 259, type: 3, count: 1, value: compression.value);
    entryOffset = _writeEntry(data, entryOffset, tag: 262, type: 3, count: 1, value: 2);
    entryOffset = _writeEntry(data, entryOffset, tag: 273, type: 4, count: 1, value: pixelOffset);
    entryOffset = _writeEntry(data, entryOffset, tag: 274, type: 3, count: 1, value: 1);
    entryOffset = _writeEntry(data, entryOffset, tag: 277, type: 3, count: 1, value: 4);
    entryOffset = _writeEntry(data, entryOffset, tag: 278, type: 4, count: 1, value: image.height);
    entryOffset = _writeEntry(data, entryOffset, tag: 279, type: 4, count: 1, value: encodedPixels.length);
    entryOffset = _writeEntry(data, entryOffset, tag: 282, type: 5, count: 1, value: resolutionOffset);
    entryOffset = _writeEntry(data, entryOffset, tag: 283, type: 5, count: 1, value: resolutionOffset + 8);
    entryOffset = _writeEntry(data, entryOffset, tag: 284, type: 3, count: 1, value: 1);
    entryOffset = _writeEntry(data, entryOffset, tag: 296, type: 3, count: 1, value: 2);
    entryOffset = _writeEntry(data, entryOffset, tag: 338, type: 3, count: 1, value: 2);
    data.setUint32(entryOffset, 0, Endian.little);
    for (int index = 0; index < 4; index++) {
      data.setUint16(bitsPerSampleOffset + index * 2, 8, Endian.little);
    }
    for (int index = 0; index < 2; index++) {
      data
        ..setUint32(resolutionOffset + index * 8, 72, Endian.little)
        ..setUint32(resolutionOffset + index * 8 + 4, 1, Endian.little);
    }
    data.buffer.asUint8List().setRange(pixelOffset, pixelOffset + encodedPixels.length, encodedPixels);
    return data.buffer.asUint8List();
  }

  /// Writes one little-endian image-file-directory entry.
  int _writeEntry(
    ByteData data,
    int offset, {
    required int tag,
    required int type,
    required int count,
    required int value,
  }) {
    data
      ..setUint16(offset, tag, Endian.little)
      ..setUint16(offset + 2, type, Endian.little)
      ..setUint32(offset + 4, count, Endian.little);
    if (type == 3 && count == 1) {
      data
        ..setUint16(offset + 8, value, Endian.little)
        ..setUint16(offset + 10, 0, Endian.little);
    } else {
      data.setUint32(offset + 8, value, Endian.little);
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
