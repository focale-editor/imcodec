part of '../gif.dart';

/// Decodes the first visible GIF frame to straight RGBA pixels.
final class GifDecoder extends RasterDecoder {
  /// Creates a GIF decoder.
  const GifDecoder();

  /// Decodes the first image descriptor in [bytes].
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    final InputBuffer input = InputBuffer(bytes);
    _readSignature(input);
    final int canvasWidth = input.readUint16();
    final int canvasHeight = input.readUint16();
    _checkDimensions(canvasWidth, canvasHeight, maxPixels);
    final int screenFlags = input.readUint8();
    input
      ..readUint8()
      ..readUint8();
    final List<_GifColor>? globalColorTable = (screenFlags & 0x80) == 0 ? null : _readColorTable(input, 1 << ((screenFlags & 0x07) + 1));
    int? transparentIndex;
    while (input.remaining > 0) {
      final int introducer = input.readUint8();
      switch (introducer) {
        case 0x21:
          final int label = input.readUint8();
          if (label == 0xf9) {
            transparentIndex = _readGraphicControl(input);
          } else {
            _skipSubBlocks(input);
          }
        case 0x2c:
          return _readImage(
            input,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            globalColorTable: globalColorTable,
            transparentIndex: transparentIndex,
          );
        case 0x3b:
          throw const ImageCodecException('GIF contains no image frame');
        default:
          throw ImageCodecException(
            'Unsupported GIF block introducer: 0x${introducer.toRadixString(16)}',
          );
      }
    }
    throw const ImageCodecException('GIF trailer is missing');
  }

  /// Validates and consumes the GIF87a or GIF89a header.
  static void _readSignature(InputBuffer input) {
    input.ensure(6);
    final Uint8List signature = input.readBytes(6);
    final bool validPrefix = signature[0] == 0x47 && signature[1] == 0x49 && signature[2] == 0x46 && signature[3] == 0x38 && signature[5] == 0x61;
    if (!validPrefix || (signature[4] != 0x37 && signature[4] != 0x39)) {
      throw const ImageCodecException('Invalid GIF signature');
    }
  }

  /// Rejects invalid logical-screen allocations.
  static void _checkDimensions(int width, int height, int maxPixels) {
    if (maxPixels < 1) {
      throw RangeError.range(maxPixels, 1, null, 'maxPixels');
    }
    if (width == 0 || height == 0) {
      throw const ImageCodecException('GIF dimensions must be non-zero');
    }
    final int pixelCount = width * height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException(
        'Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit',
      );
    }
  }

  /// Reads [length] RGB entries.
  static List<_GifColor> _readColorTable(InputBuffer input, int length) => List.unmodifiable([
    for (int index = 0; index < length; index++)
      _GifColor(
        red: input.readUint8(),
        green: input.readUint8(),
        blue: input.readUint8(),
      ),
  ]);

  /// Reads a graphic-control extension and returns its transparent index.
  static int? _readGraphicControl(InputBuffer input) {
    if (input.readUint8() != 4) {
      throw const ImageCodecException(
        'GIF graphic-control extension has an invalid size',
      );
    }
    final int flags = input.readUint8();
    input.readUint16();
    final int index = input.readUint8();
    if (input.readUint8() != 0) {
      throw const ImageCodecException(
        'GIF graphic-control extension is not terminated',
      );
    }
    return (flags & 1) == 0 ? null : index;
  }

  /// Skips a chain of length-prefixed data blocks.
  static void _skipSubBlocks(InputBuffer input) {
    while (true) {
      final int length = input.readUint8();
      if (length == 0) {
        return;
      }
      input.skip(length);
    }
  }

  /// Decodes one image descriptor and composites it into the logical screen.
  static Image _readImage(
    InputBuffer input, {
    required int canvasWidth,
    required int canvasHeight,
    required List<_GifColor>? globalColorTable,
    required int? transparentIndex,
  }) {
    final int left = input.readUint16();
    final int top = input.readUint16();
    final int width = input.readUint16();
    final int height = input.readUint16();
    if (width == 0 || height == 0 || left + width > canvasWidth || top + height > canvasHeight) {
      throw const ImageCodecException(
        'GIF image descriptor exceeds its logical screen',
      );
    }
    final int flags = input.readUint8();
    final List<_GifColor>? localColorTable = (flags & 0x80) == 0 ? null : _readColorTable(input, 1 << ((flags & 0x07) + 1));
    final List<_GifColor>? colorTable = localColorTable ?? globalColorTable;
    if (colorTable == null) {
      throw const ImageCodecException('GIF image has no colour table');
    }
    final int minimumCodeSize = input.readUint8();
    final Uint8List compressed = _readSubBlocks(input);
    final Uint8List indices = _GifLzwDecoder.decode(
      compressed,
      minimumCodeSize: minimumCodeSize,
      expectedLength: width * height,
    );
    final Image result = Image(width: canvasWidth, height: canvasHeight);
    int source = 0;
    for (final int row in _rowOrder(height, interlaced: (flags & 0x40) != 0)) {
      for (int x = 0; x < width; x++) {
        final int paletteIndex = indices[source++];
        if (paletteIndex >= colorTable.length) {
          throw const ImageCodecException(
            'GIF pixel references a missing palette entry',
          );
        }
        if (paletteIndex == transparentIndex) {
          continue;
        }
        final _GifColor color = colorTable[paletteIndex];
        result.setPixelRgb(
          left + x,
          top + row,
          color.red,
          color.green,
          color.blue,
        );
      }
    }
    return result;
  }

  /// Concatenates one GIF data-sub-block chain.
  static Uint8List _readSubBlocks(InputBuffer input) {
    final BytesBuilder data = BytesBuilder(copy: false);
    while (true) {
      final int length = input.readUint8();
      if (length == 0) {
        return data.takeBytes();
      }
      data.add(input.readBytes(length));
    }
  }

  /// Returns decoded destination rows in stored GIF order.
  static Iterable<int> _rowOrder(
    int height, {
    required bool interlaced,
  }) sync* {
    if (!interlaced) {
      for (int row = 0; row < height; row++) {
        yield row;
      }
      return;
    }
    for (final (int first, int step) in const [
      (0, 8),
      (4, 8),
      (2, 4),
      (1, 2),
    ]) {
      for (int row = first; row < height; row += step) {
        yield row;
      }
    }
  }
}

/// Stores one GIF colour-table entry.
final class _GifColor {
  /// Red channel.
  final int red;

  /// Green channel.
  final int green;

  /// Blue channel.
  final int blue;

  /// Creates one colour-table entry.
  const _GifColor({
    required this.red,
    required this.green,
    required this.blue,
  });
}
