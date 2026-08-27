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
    _writeChunk(output, _ihdr, header.getBytes());

    final Uint8List filtered = _filter(image);
    final Uint8List compressed = Uint8List.fromList(const ZlibCodec().encode(filtered, level: level));
    _writeChunk(output, _idat, compressed);
    _writeChunk(output, _iend, Uint8List(0));
    return output.takeBytes();
  }

  /// Applies the lowest-cost PNG predictor independently to every row.
  /// Candidates are written into alternating scratch rows so the winning row
  /// is copied once, and a candidate is abandoned as soon as its running cost
  /// can no longer win.
  Uint8List _filter(Image image) {
    const int bytesPerPixel = 4;
    final int rowLength = image.width * bytesPerPixel;
    final Uint8List source = image.bytes;
    final Uint8List result = Uint8List((rowLength + 1) * image.height);
    Uint8List candidate = Uint8List(rowLength);
    Uint8List best = Uint8List(rowLength);
    for (int y = 0; y < image.height; y++) {
      final int sourceOffset = y * rowLength;
      final int previousOffset = sourceOffset - rowLength;
      int bestFilter = 0;
      int bestScore = -1;
      for (int filter = 0; filter <= 4; filter++) {
        final int score = _applyFilter(source, candidate, sourceOffset, previousOffset, rowLength, bytesPerPixel, filter, y > 0, bestScore);
        if (score >= 0 && (bestScore < 0 || score < bestScore)) {
          bestFilter = filter;
          bestScore = score;
          final Uint8List previousBest = best;
          best = candidate;
          candidate = previousBest;
        }
      }
      final int destinationOffset = y * (rowLength + 1);
      result[destinationOffset] = bestFilter;
      result.setRange(destinationOffset + 1, destinationOffset + rowLength + 1, best);
    }
    return result;
  }

  /// Filters one row with [filter] and returns its absolute-difference score.
  /// Returns -1 when the score passes [scoreLimit], which means the row can no
  /// longer be the cheapest choice.
  static int _applyFilter(
    Uint8List source,
    Uint8List destination,
    int sourceOffset,
    int previousOffset,
    int rowLength,
    int bytesPerPixel,
    int filter,
    bool hasPreviousRow,
    int scoreLimit,
  ) {
    if (!hasPreviousRow && (filter == 2 || filter == 4)) {
      // Without a previous row these filters degrade to filters already tried.
      return -1;
    }
    final int leading = bytesPerPixel < rowLength ? bytesPerPixel : rowLength;
    int score = 0;
    switch (filter) {
      case 0:
        for (int x = 0; x < rowLength; x++) {
          final int value = source[sourceOffset + x];
          destination[x] = value;
          score += value < 128 ? value : 256 - value;
          if (scoreLimit >= 0 && score >= scoreLimit) {
            return -1;
          }
        }
      case 1:
        for (int x = 0; x < leading; x++) {
          final int value = source[sourceOffset + x];
          destination[x] = value;
          score += value < 128 ? value : 256 - value;
        }
        for (int x = bytesPerPixel; x < rowLength; x++) {
          final int value = (source[sourceOffset + x] - source[sourceOffset + x - bytesPerPixel]) & 0xff;
          destination[x] = value;
          score += value < 128 ? value : 256 - value;
          if (scoreLimit >= 0 && score >= scoreLimit) {
            return -1;
          }
        }
      case 2:
        for (int x = 0; x < rowLength; x++) {
          final int value = (source[sourceOffset + x] - source[previousOffset + x]) & 0xff;
          destination[x] = value;
          score += value < 128 ? value : 256 - value;
          if (scoreLimit >= 0 && score >= scoreLimit) {
            return -1;
          }
        }
      case 3:
        for (int x = 0; x < leading; x++) {
          final int up = hasPreviousRow ? source[previousOffset + x] : 0;
          final int value = (source[sourceOffset + x] - (up >> 1)) & 0xff;
          destination[x] = value;
          score += value < 128 ? value : 256 - value;
        }
        if (hasPreviousRow) {
          for (int x = bytesPerPixel; x < rowLength; x++) {
            final int value = (source[sourceOffset + x] - ((source[sourceOffset + x - bytesPerPixel] + source[previousOffset + x]) >> 1)) & 0xff;
            destination[x] = value;
            score += value < 128 ? value : 256 - value;
            if (scoreLimit >= 0 && score >= scoreLimit) {
              return -1;
            }
          }
        } else {
          for (int x = bytesPerPixel; x < rowLength; x++) {
            final int value = (source[sourceOffset + x] - (source[sourceOffset + x - bytesPerPixel] >> 1)) & 0xff;
            destination[x] = value;
            score += value < 128 ? value : 256 - value;
            if (scoreLimit >= 0 && score >= scoreLimit) {
              return -1;
            }
          }
        }
      default:
        for (int x = 0; x < leading; x++) {
          final int value = (source[sourceOffset + x] - source[previousOffset + x]) & 0xff;
          destination[x] = value;
          score += value < 128 ? value : 256 - value;
        }
        for (int x = bytesPerPixel; x < rowLength; x++) {
          final int value = (source[sourceOffset + x] - _paeth(source[sourceOffset + x - bytesPerPixel], source[previousOffset + x], source[previousOffset + x - bytesPerPixel])) & 0xff;
          destination[x] = value;
          score += value < 128 ? value : 256 - value;
          if (scoreLimit >= 0 && score >= scoreLimit) {
            return -1;
          }
        }
    }
    return score;
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
