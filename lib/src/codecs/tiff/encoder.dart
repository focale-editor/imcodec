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
  static const int _entryCount = 12;

  /// Compression used when encoding pixel strips.
  final TiffCompression compression;

  /// Creates a baseline TIFF encoder.
  const TiffEncoder({
    this.compression = TiffCompression.packBits,
  });

  /// Encodes [image] as a little-endian, chunky, eight-bit RGBA TIFF image.
  @override
  Uint8List encode(Image image) {
    final Uint8List rawPixels = _rgbaBytes(image);
    final Uint8List encodedPixels = switch (compression) {
      TiffCompression.none => rawPixels,
      TiffCompression.packBits => _encodePackBits(rawPixels),
    };
    const int firstIfdOffset = 8;
    const int ifdSize = 2 + _entryCount * 12 + 4;
    const int bitsPerSampleOffset = firstIfdOffset + ifdSize;
    const int bitsPerSampleSize = 8;
    const int pixelOffset = bitsPerSampleOffset + bitsPerSampleSize;
    final ByteData data = ByteData(pixelOffset + encodedPixels.length);

    data
      ..setUint8(0, 0x49)
      ..setUint8(1, 0x49)
      ..setUint16(2, 42, Endian.little)
      ..setUint32(4, firstIfdOffset, Endian.little)
      ..setUint16(firstIfdOffset, _entryCount, Endian.little);

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
    entryOffset = _writeEntry(data, entryOffset, tag: 284, type: 3, count: 1, value: 1);
    entryOffset = _writeEntry(data, entryOffset, tag: 338, type: 3, count: 1, value: 2);
    data.setUint32(entryOffset, 0, Endian.little);
    for (int index = 0; index < 4; index++) {
      data.setUint16(bitsPerSampleOffset + index * 2, 8, Endian.little);
    }
    data.buffer.asUint8List().setRange(pixelOffset, pixelOffset + encodedPixels.length, encodedPixels);
    return data.buffer.asUint8List();
  }

  /// Copies the source pixels into a tightly packed TIFF strip.
  Uint8List _rgbaBytes(Image image) => Uint8List.fromList(image.bytes);

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

  /// Compresses bytes using TIFF PackBits packets.
  Uint8List _encodePackBits(Uint8List input) {
    final BytesBuilder output = BytesBuilder(copy: false);
    int position = 0;
    while (position < input.length) {
      int runLength = 1;
      while (runLength < 128 && position + runLength < input.length && input[position + runLength] == input[position]) {
        runLength++;
      }
      if (runLength >= 3) {
        output.add([257 - runLength, input[position]]);
        position += runLength;
        continue;
      }

      final int literalStart = position;
      position += runLength;
      while (position < input.length && position - literalStart < 128) {
        runLength = 1;
        while (runLength < 128 && position + runLength < input.length && input[position + runLength] == input[position]) {
          runLength++;
        }
        if (runLength >= 3) {
          break;
        }
        position += runLength;
      }
      final int literalLength = position - literalStart;
      output
        ..add([literalLength - 1])
        ..add(Uint8List.sublistView(input, literalStart, position));
    }
    return output.takeBytes();
  }
}
