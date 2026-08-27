part of '../png.dart';

/// Small PNGs do not contain enough filtering work to cover isolate overhead.
const int _minimumPngParallelPixels = 512 * 512;

/// Maximum number of independently filtered row bands.
const int _maximumPngParallelJobs = 4;

/// Carries consecutive PNG rows and the optional preceding source row.
final class _PngFilterJob {
  /// RGBA rows, prefixed by one halo row when [hasPreviousRow] is true.
  final Uint8List pixels;

  /// Number of pixels in each source row.
  final int width;

  /// Number of rows to filter, excluding the optional halo.
  final int rowCount;

  /// Whether [pixels] starts with the row preceding the output band.
  final bool hasPreviousRow;

  /// Creates one self-contained filtering job.
  const _PngFilterJob({
    required this.pixels,
    required this.width,
    required this.rowCount,
    required this.hasPreviousRow,
  });
}

/// Filters one row band without reading or mutating shared state.
Uint8List _runPngFilterJob(_PngFilterJob job) => PngEncoder._filterRows(
  job.pixels,
  width: job.width,
  rowCount: job.rowCount,
  hasPreviousRow: job.hasPreviousRow,
);

/// Encodes images as Portable Network Graphics data.
final class PngEncoder extends RasterEncoder with ParallelRasterEncoder {
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
    _checkInput(image);
    return _encodeFiltered(
      _filter(image),
      width: image.width,
      height: image.height,
    );
  }

  @override
  Future<Uint8List> encodeWith(ParallelRunner runner, Image input) async {
    _checkInput(input);
    if (input.width * input.height < _minimumPngParallelPixels || input.height < 2) {
      return encode(input);
    }

    final int jobCount = input.height < _maximumPngParallelJobs ? input.height : _maximumPngParallelJobs;
    final int rowLength = input.width * 4;
    final List<_PngFilterJob> jobs = <_PngFilterJob>[];
    for (int jobIndex = 0; jobIndex < jobCount; jobIndex++) {
      final int firstRow = jobIndex * input.height ~/ jobCount;
      final int lastRow = (jobIndex + 1) * input.height ~/ jobCount;
      final bool hasPreviousRow = firstRow > 0;
      final int firstSourceRow = hasPreviousRow ? firstRow - 1 : firstRow;
      jobs.add(
        _PngFilterJob(
          pixels: Uint8List.fromList(
            Uint8List.sublistView(
              input.bytes,
              firstSourceRow * rowLength,
              lastRow * rowLength,
            ),
          ),
          width: input.width,
          rowCount: lastRow - firstRow,
          hasPreviousRow: hasPreviousRow,
        ),
      );
    }
    final List<Uint8List> filteredBands = await runner<_PngFilterJob, Uint8List>(
      jobs,
      _runPngFilterJob,
    );
    final Uint8List filtered = Uint8List((rowLength + 1) * input.height);
    int destination = 0;
    for (final Uint8List band in filteredBands) {
      filtered.setRange(destination, destination + band.length, band);
      destination += band.length;
    }
    return _encodeFiltered(
      filtered,
      width: input.width,
      height: input.height,
    );
  }

  /// Validates options and dimensions before any output is allocated.
  void _checkInput(Image image) {
    if (level < 0 || level > 9) {
      throw RangeError.range(level, 0, 9, 'level');
    }
    if (image.width > 0x7fffffff || image.height > 0x7fffffff) {
      throw const ImageCodecException('PNG dimensions may not exceed 2147483647 pixels');
    }
  }

  /// Compresses already filtered rows and wraps them in PNG chunks.
  Uint8List _encodeFiltered(
    Uint8List filtered, {
    required int width,
    required int height,
  }) {
    final OutputBuffer output = OutputBuffer(bigEndian: true)..writeBytes(_signature);
    final OutputBuffer header = OutputBuffer(bigEndian: true)
      ..writeUint32(width)
      ..writeUint32(height)
      ..writeByte(8)
      ..writeByte(6)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0);
    _writeChunk(output, _ihdr, header.getBytes());

    final Uint8List compressed = Uint8List.fromList(const ZlibCodec().encode(filtered, level: level));
    _writeChunk(output, _idat, compressed);
    _writeChunk(output, _iend, Uint8List(0));
    return output.takeBytes();
  }

  /// Applies the lowest-cost PNG predictor independently to every row.
  /// Candidates are written into alternating scratch rows so the winning row
  /// is copied once, and a candidate is abandoned as soon as its running cost
  /// can no longer win.
  Uint8List _filter(Image image) => _filterRows(
    image.bytes,
    width: image.width,
    rowCount: image.height,
    hasPreviousRow: false,
  );

  /// Filters [rowCount] rows, using an optional leading source halo row.
  static Uint8List _filterRows(
    Uint8List source, {
    required int width,
    required int rowCount,
    required bool hasPreviousRow,
  }) {
    const int bytesPerPixel = 4;
    final int rowLength = width * bytesPerPixel;
    final int sourceRowOffset = hasPreviousRow ? 1 : 0;
    final Uint8List result = Uint8List((rowLength + 1) * rowCount);
    Uint8List candidate = Uint8List(rowLength);
    Uint8List best = Uint8List(rowLength);
    for (int y = 0; y < rowCount; y++) {
      final int sourceOffset = (y + sourceRowOffset) * rowLength;
      final int previousOffset = sourceOffset - rowLength;
      final bool rowHasPrevious = hasPreviousRow || y > 0;
      int bestFilter = 0;
      int bestScore = -1;
      for (int filter = 0; filter <= 4; filter++) {
        final int score = _applyFilter(source, candidate, sourceOffset, previousOffset, rowLength, bytesPerPixel, filter, rowHasPrevious, bestScore);
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
