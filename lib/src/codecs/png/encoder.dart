part of '../png.dart';

/// Encodes images as Portable Network Graphics data.
final class PngEncoder extends RasterEncoder {
  /// Eight-byte PNG file signature.
  static const List<int> _signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

  /// Chunk type bytes for the image header.
  static const List<int> _ihdr = [0x49, 0x48, 0x44, 0x52];

  /// Chunk type bytes for compressed image data.
  static const List<int> _idat = [0x49, 0x44, 0x41, 0x54];

  /// Chunk type bytes for the end marker.
  static const List<int> _iend = [0x49, 0x45, 0x4e, 0x44];

  /// Zlib compression level.
  final int level;

  /// Creates a codec using a zlib [level] from 0 through 9.
  const PngEncoder({
    this.level = 6,
  }) : assert(level >= 0 && level <= 9, 'PNG compression level must be between 0 and 9');

  /// Encodes [image] as an eight-bit RGBA PNG image.
  @override
  Uint8List encode(Image image) {
    if (level < 0 || level > 9) {
      throw RangeError.range(level, 0, 9, 'level');
    }
    if (image.width > 0x7fffffff || image.height > 0x7fffffff) {
      throw const ImageCodecException('PNG dimensions may not exceed 2147483647 pixels');
    }

    final OutputBuffer output = OutputBuffer(bigEndian: true)..writeBytes(_signature);
    final OutputBuffer header = OutputBuffer(bigEndian: true)
      ..writeUint32(image.width)
      ..writeUint32(image.height)
      ..writeByte(8)
      ..writeByte(6)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0);
    _writeChunk(output, _ihdr, Uint8List.fromList(header.getBytes()));

    final Uint8List filtered = _filter(image);
    final Uint8List compressed = Uint8List.fromList(const ZlibCodec().encode(filtered, level: level));
    _writeChunk(output, _idat, compressed);
    _writeChunk(output, _iend, Uint8List(0));
    return Uint8List.fromList(output.getBytes());
  }

  /// Applies the lowest-cost PNG predictor independently to every row.
  Uint8List _filter(Image image) {
    final int rowLength = image.width * 4;
    final Uint8List result = Uint8List((rowLength + 1) * image.height);
    final Uint8List candidate = Uint8List(rowLength);
    final Uint8List best = Uint8List(rowLength);
    for (int y = 0; y < image.height; y++) {
      final int sourceOffset = y * rowLength;
      int bestFilter = 0;
      int bestScore = 0x7fffffffffffffff;
      for (int filter = 0; filter <= 4; filter++) {
        int score = 0;
        for (int x = 0; x < rowLength; x++) {
          final int value = image.bytes[sourceOffset + x];
          final int left = x >= 4 ? image.bytes[sourceOffset + x - 4] : 0;
          final int up = y > 0 ? image.bytes[sourceOffset - rowLength + x] : 0;
          final int upperLeft = y > 0 && x >= 4 ? image.bytes[sourceOffset - rowLength + x - 4] : 0;
          final int predictor = switch (filter) {
            0 => 0,
            1 => left,
            2 => up,
            3 => (left + up) >> 1,
            4 => _paeth(left, up, upperLeft),
            _ => throw StateError('Unknown PNG filter'),
          };
          final int filteredValue = (value - predictor) & 0xff;
          candidate[x] = filteredValue;
          score += filteredValue < 128 ? filteredValue : 256 - filteredValue;
        }
        if (score < bestScore) {
          bestFilter = filter;
          bestScore = score;
          best.setAll(0, candidate);
        }
      }
      final int destinationOffset = y * (rowLength + 1);
      result[destinationOffset] = bestFilter;
      result.setRange(destinationOffset + 1, destinationOffset + rowLength + 1, best);
    }
    return result;
  }

  /// Predicts one byte from its left, upper, and upper-left neighbors.
  static int _paeth(int left, int up, int upperLeft) {
    final int prediction = left + up - upperLeft;
    final int leftDistance = (prediction - left).abs();
    final int upDistance = (prediction - up).abs();
    final int upperLeftDistance = (prediction - upperLeft).abs();
    if (leftDistance <= upDistance && leftDistance <= upperLeftDistance) {
      return left;
    }
    return upDistance <= upperLeftDistance ? up : upperLeft;
  }

  /// Writes a length-prefixed PNG chunk followed by its checksum.
  static void _writeChunk(OutputBuffer output, List<int> type, Uint8List data) {
    output
      ..writeUint32(data.length)
      ..writeBytes(type)
      ..writeBytes(data)
      ..writeUint32(_crc32(type, data));
  }

  /// Computes the PNG CRC-32 over a chunk type and its payload.
  static int _crc32(List<int> type, Uint8List data) => _PngChecksum.compute(type, data);
}
