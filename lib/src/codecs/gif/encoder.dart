part of '../gif.dart';

/// Encodes a single image as GIF89a data.
final class GifEncoder extends RasterEncoder {
  /// GIF89a signature and version bytes.
  static const List<int> _signature = [
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
  ];

  /// Palette reduction settings.
  final IndexedColorOptions options;

  /// Creates a static GIF encoder.
  const GifEncoder({
    this.options = const IndexedColorOptions(),
  });

  /// Quantizes and encodes [image] as one GIF frame.
  @override
  Uint8List encode(Image image) {
    if (image.width > 0xffff || image.height > 0xffff) {
      throw const ImageCodecException(
        'GIF dimensions may not exceed 65535 pixels',
      );
    }
    final IndexedColorImage indexed = quantizeIndexedColor(
      image,
      options: options,
    );
    final int tableSize = _tableSize(indexed.paletteLength);
    final int tableBits = tableSize.bitLength - 1;
    final OutputBuffer output = OutputBuffer()
      ..writeBytes(_signature)
      ..writeUint16(image.width)
      ..writeUint16(image.height)
      ..writeByte(0x80 | 0x70 | (tableBits - 1))
      ..writeByte(0)
      ..writeByte(0);
    _writeColorTable(output, indexed.palette, tableSize);
    if (indexed.transparentIndex case final int transparentIndex) {
      output
        ..writeByte(0x21)
        ..writeByte(0xf9)
        ..writeByte(4)
        ..writeByte(1)
        ..writeUint16(0)
        ..writeByte(transparentIndex)
        ..writeByte(0);
    }
    output
      ..writeByte(0x2c)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(image.width)
      ..writeUint16(image.height)
      ..writeByte(0);
    final int minimumCodeSize = tableBits < 2 ? 2 : tableBits;
    output.writeByte(minimumCodeSize);
    final Uint8List compressed = _GifLzwEncoder.encode(
      indexed.indices,
      minimumCodeSize: minimumCodeSize,
    );
    int offset = 0;
    while (offset < compressed.length) {
      final int length = compressed.length - offset > 255 ? 255 : compressed.length - offset;
      output
        ..writeByte(length)
        ..writeBytes(Uint8List.sublistView(compressed, offset, offset + length));
      offset += length;
    }
    output
      ..writeByte(0)
      ..writeByte(0x3b);
    return output.takeBytes();
  }

  /// Returns the power-of-two table size required by [paletteLength].
  static int _tableSize(int paletteLength) {
    int size = 2;
    while (size < paletteLength) {
      size <<= 1;
    }
    return size;
  }

  /// Writes RGB entries and pads the global colour table to [tableSize].
  static void _writeColorTable(
    OutputBuffer output,
    Uint8List palette,
    int tableSize,
  ) {
    for (int index = 0; index < tableSize; index++) {
      if (index < palette.length ~/ 4) {
        final int offset = index * 4;
        output
          ..writeByte(palette[offset])
          ..writeByte(palette[offset + 1])
          ..writeByte(palette[offset + 2]);
      } else {
        output
          ..writeByte(0)
          ..writeByte(0)
          ..writeByte(0);
      }
    }
  }
}
