part of '../jpeg.dart';

/// Selects the chroma sampling used by the JPEG encoder.
enum JpegChroma {
  /// Preserves one chroma sample per luma sample.
  yuv444,

  /// Shares chroma samples across each 2 by 2 luma block.
  yuv420,
}

/// Encodes images as baseline JPEG data.
///
/// The implementation uses a forward discrete cosine transform and canonical
/// JPEG Huffman tables.
final class JpegEncoder extends RasterEncoder with ParallelRasterEncoder {
  /// Compression quality from 1 through 100.
  final int quality;

  /// Chroma sampling used by the encoder.
  final JpegChroma chroma;

  /// Creates an immutable baseline JPEG encoder configuration.
  const JpegEncoder({
    this.quality = 100,
    this.chroma = JpegChroma.yuv444,
  });

  @override
  Uint8List encode(Image image) => _JpegEncodingSession(
    quality: quality,
    chroma: chroma,
  ).encode(image);

  @override
  Future<Uint8List> encodeWith(ParallelRunner runner, Image input) async {
    final _JpegEncodingSession session = _JpegEncodingSession(
      quality: quality,
      chroma: chroma,
    );
    session._checkDimensions(input);

    final int mcuHeight = chroma == JpegChroma.yuv444 ? 8 : 16;
    final int mcuRowCount = (input.height + mcuHeight - 1) ~/ mcuHeight;
    if (input.width * input.height < _minimumJpegParallelPixels || mcuRowCount < 2) {
      return session.encode(input);
    }

    final List<_JpegBandJob> jobs = _createJpegBandJobs(
      input,
      quality: quality,
      chroma: chroma,
      mcuHeight: mcuHeight,
      mcuRowCount: mcuRowCount,
    );
    final List<_JpegBandResult> bands = await runner<_JpegBandJob, _JpegBandResult>(
      jobs,
      _runJpegBandJob,
    );
    return session._encodeTransformedBands(
      bands,
      width: input.width,
      height: input.height,
    );
  }
}

/// Small images finish before isolate startup and message transfer pay off.
const int _minimumJpegParallelPixels = 1024 * 1024;

/// Maximum number of independently transformed JPEG bands.
const int _maximumJpegParallelJobs = 4;

/// Describes a complete set of MCU rows that can be transformed independently.
final class _JpegBandJob {
  /// Tightly packed RGBA rows in this band.
  final Uint8List pixels;

  /// Image width shared by every row in [pixels].
  final int width;

  /// Number of source rows in this band.
  final int height;

  /// Quantization quality used by the parent encode.
  final int quality;

  /// Chroma layout used by the parent encode.
  final JpegChroma chroma;

  /// Creates one self-contained transform job.
  const _JpegBandJob({
    required this.pixels,
    required this.width,
    required this.height,
    required this.quality,
    required this.chroma,
  });
}

/// Holds zigzag-ordered coefficients for consecutive MCU rows.
final class _JpegBandResult {
  /// Quantized coefficients in scan order, with 64 entries per data unit.
  final Int16List coefficients;

  /// Creates one transformed band result.
  const _JpegBandResult({
    required this.coefficients,
  });
}

/// Splits [image] on MCU-row boundaries without duplicating source pixels.
List<_JpegBandJob> _createJpegBandJobs(
  Image image, {
  required int quality,
  required JpegChroma chroma,
  required int mcuHeight,
  required int mcuRowCount,
}) {
  final int jobCount = mcuRowCount < _maximumJpegParallelJobs ? mcuRowCount : _maximumJpegParallelJobs;
  final List<_JpegBandJob> jobs = <_JpegBandJob>[];
  for (int jobIndex = 0; jobIndex < jobCount; jobIndex++) {
    final int firstMcuRow = jobIndex * mcuRowCount ~/ jobCount;
    final int lastMcuRow = (jobIndex + 1) * mcuRowCount ~/ jobCount;
    final int firstRow = firstMcuRow * mcuHeight;
    final int unclampedLastRow = lastMcuRow * mcuHeight;
    final int lastRow = unclampedLastRow < image.height ? unclampedLastRow : image.height;
    final int firstByte = firstRow * image.width * 4;
    final int lastByte = lastRow * image.width * 4;
    jobs.add(
      _JpegBandJob(
        pixels: Uint8List.fromList(Uint8List.sublistView(image.bytes, firstByte, lastByte)),
        width: image.width,
        height: lastRow - firstRow,
        quality: quality,
        chroma: chroma,
      ),
    );
  }
  return jobs;
}

/// Transforms one JPEG band without reading or mutating shared state.
_JpegBandResult _runJpegBandJob(_JpegBandJob job) =>
    _JpegEncodingSession(
      quality: job.quality,
      chroma: job.chroma,
    )._transformBand(
      job.pixels,
      width: job.width,
      height: job.height,
    );

/// Holds the mutable state for one baseline JPEG encoding operation.
final class _JpegEncodingSession {
  /// Quality-scaled luminance quantization values in zigzag order.
  final Uint8List _yTable = Uint8List(64);

  /// Quality-scaled chrominance quantization values in zigzag order.
  final Uint8List _uvTable = Uint8List(64);

  /// Forward-transform scaling factors for luminance coefficients.
  final Float32List _luminanceTransformFactors = Float32List(64);

  /// Forward-transform scaling factors for chrominance coefficients.
  final Float32List _chrominanceTransformFactors = Float32List(64);

  /// Huffman lookup table for luminance DC coefficients.
  late final JpegHuffmanCodeTable _luminanceDcHuffmanTable;

  /// Huffman lookup table for chrominance DC coefficients.
  late final JpegHuffmanCodeTable _chrominanceDcHuffmanTable;

  /// Huffman lookup table for luminance AC coefficients.
  late final JpegHuffmanCodeTable _luminanceAcHuffmanTable;

  /// Huffman lookup table for chrominance AC coefficients.
  late final JpegHuffmanCodeTable _chrominanceAcHuffmanTable;

  /// Reusable output storage for transformed and quantized coefficients.
  final Int32List _quantizedCoefficients = Int32List(64);

  /// Reusable zigzag-ordered data-unit coefficients.
  /// Quantized coefficients fit in sixteen bits, which lets the sequential and
  /// the band-parallel paths share one block-writing routine.
  final Int16List _zigzagCoefficients = Int16List(64);

  /// Fixed-point products used by RGB-to-YUV conversion.
  final Int32List _rgbToYuvTable = Int32List(2048);

  /// Chroma sampling used by this encoder.
  final JpegChroma chroma;

  /// Quality the quantization tables were built for.
  final int quality;

  /// Number of luminance DC codes for each bit length.
  static const List<int> _standardLuminanceDcCodeCounts = [0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];

  /// Luminance DC symbols in canonical order.
  static const List<int> _standardLuminanceDcValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

  /// Number of luminance AC codes for each bit length.
  static const List<int> _standardLuminanceAcCodeCounts = [0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];

  /// Luminance AC symbols in canonical order.
  static const List<int> _standardLuminanceAcValues = [
    0x01,
    0x02,
    0x03,
    0x00,
    0x04,
    0x11,
    0x05,
    0x12,
    0x21,
    0x31,
    0x41,
    0x06,
    0x13,
    0x51,
    0x61,
    0x07,
    0x22,
    0x71,
    0x14,
    0x32,
    0x81,
    0x91,
    0xa1,
    0x08,
    0x23,
    0x42,
    0xb1,
    0xc1,
    0x15,
    0x52,
    0xd1,
    0xf0,
    0x24,
    0x33,
    0x62,
    0x72,
    0x82,
    0x09,
    0x0a,
    0x16,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x25,
    0x26,
    0x27,
    0x28,
    0x29,
    0x2a,
    0x34,
    0x35,
    0x36,
    0x37,
    0x38,
    0x39,
    0x3a,
    0x43,
    0x44,
    0x45,
    0x46,
    0x47,
    0x48,
    0x49,
    0x4a,
    0x53,
    0x54,
    0x55,
    0x56,
    0x57,
    0x58,
    0x59,
    0x5a,
    0x63,
    0x64,
    0x65,
    0x66,
    0x67,
    0x68,
    0x69,
    0x6a,
    0x73,
    0x74,
    0x75,
    0x76,
    0x77,
    0x78,
    0x79,
    0x7a,
    0x83,
    0x84,
    0x85,
    0x86,
    0x87,
    0x88,
    0x89,
    0x8a,
    0x92,
    0x93,
    0x94,
    0x95,
    0x96,
    0x97,
    0x98,
    0x99,
    0x9a,
    0xa2,
    0xa3,
    0xa4,
    0xa5,
    0xa6,
    0xa7,
    0xa8,
    0xa9,
    0xaa,
    0xb2,
    0xb3,
    0xb4,
    0xb5,
    0xb6,
    0xb7,
    0xb8,
    0xb9,
    0xba,
    0xc2,
    0xc3,
    0xc4,
    0xc5,
    0xc6,
    0xc7,
    0xc8,
    0xc9,
    0xca,
    0xd2,
    0xd3,
    0xd4,
    0xd5,
    0xd6,
    0xd7,
    0xd8,
    0xd9,
    0xda,
    0xe1,
    0xe2,
    0xe3,
    0xe4,
    0xe5,
    0xe6,
    0xe7,
    0xe8,
    0xe9,
    0xea,
    0xf1,
    0xf2,
    0xf3,
    0xf4,
    0xf5,
    0xf6,
    0xf7,
    0xf8,
    0xf9,
    0xfa,
  ];

  /// Number of chrominance DC codes for each bit length.
  static const List<int> _standardChrominanceDcCodeCounts = [0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];

  /// Chrominance DC symbols in canonical order.
  static const List<int> _standardChrominanceDcValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

  /// Number of chrominance AC codes for each bit length.
  static const List<int> _standardChrominanceAcCodeCounts = [0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];

  /// Chrominance AC symbols in canonical order.
  static const List<int> _standardChrominanceAcValues = [
    0x00,
    0x01,
    0x02,
    0x03,
    0x11,
    0x04,
    0x05,
    0x21,
    0x31,
    0x06,
    0x12,
    0x41,
    0x51,
    0x07,
    0x61,
    0x71,
    0x13,
    0x22,
    0x32,
    0x81,
    0x08,
    0x14,
    0x42,
    0x91,
    0xa1,
    0xb1,
    0xc1,
    0x09,
    0x23,
    0x33,
    0x52,
    0xf0,
    0x15,
    0x62,
    0x72,
    0xd1,
    0x0a,
    0x16,
    0x24,
    0x34,
    0xe1,
    0x25,
    0xf1,
    0x17,
    0x18,
    0x19,
    0x1a,
    0x26,
    0x27,
    0x28,
    0x29,
    0x2a,
    0x35,
    0x36,
    0x37,
    0x38,
    0x39,
    0x3a,
    0x43,
    0x44,
    0x45,
    0x46,
    0x47,
    0x48,
    0x49,
    0x4a,
    0x53,
    0x54,
    0x55,
    0x56,
    0x57,
    0x58,
    0x59,
    0x5a,
    0x63,
    0x64,
    0x65,
    0x66,
    0x67,
    0x68,
    0x69,
    0x6a,
    0x73,
    0x74,
    0x75,
    0x76,
    0x77,
    0x78,
    0x79,
    0x7a,
    0x82,
    0x83,
    0x84,
    0x85,
    0x86,
    0x87,
    0x88,
    0x89,
    0x8a,
    0x92,
    0x93,
    0x94,
    0x95,
    0x96,
    0x97,
    0x98,
    0x99,
    0x9a,
    0xa2,
    0xa3,
    0xa4,
    0xa5,
    0xa6,
    0xa7,
    0xa8,
    0xa9,
    0xaa,
    0xb2,
    0xb3,
    0xb4,
    0xb5,
    0xb6,
    0xb7,
    0xb8,
    0xb9,
    0xba,
    0xc2,
    0xc3,
    0xc4,
    0xc5,
    0xc6,
    0xc7,
    0xc8,
    0xc9,
    0xca,
    0xd2,
    0xd3,
    0xd4,
    0xd5,
    0xd6,
    0xd7,
    0xd8,
    0xd9,
    0xda,
    0xe2,
    0xe3,
    0xe4,
    0xe5,
    0xe6,
    0xe7,
    0xe8,
    0xe9,
    0xea,
    0xf2,
    0xf3,
    0xf4,
    0xf5,
    0xf6,
    0xf7,
    0xf8,
    0xf9,
    0xfa,
  ];

  /// Partially filled entropy byte.
  int _byteNew = 0;

  /// Next bit position in the entropy byte.
  int _bytePos = 7;

  /// Creates one encoding session and initializes its derived tables.
  _JpegEncodingSession({
    required this.quality,
    required this.chroma,
  }) {
    _initHuffmanTable();
    _initRgbYuvTable();
    _initializeQuality(quality);
  }

  /// Builds the quantization tables for the clamped [quality].
  void _initializeQuality(int quality) {
    final int currentQuality = quality.clamp(1, 100);

    int scaleFactor;
    if (currentQuality < 50) {
      scaleFactor = (5000 / currentQuality).floor();
    } else {
      scaleFactor = 200 - currentQuality * 2;
    }

    _initQuantTables(scaleFactor);
  }

  /// Rejects dimensions the format cannot express.
  void _checkDimensions(Image image) {
    if (image.width > 65535 || image.height > 65535) {
      throw const ImageCodecException('JPEG dimensions may not exceed 65535 pixels');
    }
  }

  /// Writes every header segment that precedes the entropy-coded scan.
  void _writeSegments(OutputBuffer output, int width, int height) {
    _writeMarker(output, JpegMarker.startOfImage);
    _writeApplicationSegment(output);
    _writeQuantizationTables(output);
    _writeStartOfFrameSegment(output, width, height, chroma);
    _writeHuffmanTables(output);
    _writeStartOfScanSegment(output);
  }

  /// Pads the final entropy byte and writes the end-of-image marker.
  void _finishScan(OutputBuffer output) {
    // Pad the final entropy byte with one bits, but only when one is partly
    // written: a byte-aligned stream needs no padding at all.
    if (_bytePos < 7) {
      final int fillBitCount = _bytePos + 1;
      _writeBits(output, (1 << fillBitCount) - 1, fillBitCount);
    }
    _writeMarker(output, JpegMarker.endOfImage);
  }

  /// Encodes [image] as a baseline JPEG using the selected [chroma] sampling.
  Uint8List encode(Image image) {
    _checkDimensions(image);
    final OutputBuffer output = OutputBuffer(bigEndian: true);
    _writeSegments(output, image.width, image.height);
    _resetBits();

    int luminancePredictor = 0;
    int blueDifferencePredictor = 0;
    int redDifferencePredictor = 0;
    final int width = image.width;
    final int height = image.height;

    if (chroma == JpegChroma.yuv444) {
      // 4:4:4 chroma: process 8x8 blocks.
      final Float32List luminanceBlock = Float32List(64);
      final Float32List blueDifferenceBlock = Float32List(64);
      final Float32List redDifferenceBlock = Float32List(64);

      for (int y = 0; y < height; y += 8) {
        for (int x = 0; x < width; x += 8) {
          _convertBlockToYuv(
            image.bytes,
            x,
            y,
            width,
            height,
            luminanceBlock,
            blueDifferenceBlock,
            redDifferenceBlock,
          );
          luminancePredictor = _encodeDataUnit(output, luminanceBlock, _luminanceTransformFactors, luminancePredictor, _luminanceDcHuffmanTable, _luminanceAcHuffmanTable);
          blueDifferencePredictor = _encodeDataUnit(output, blueDifferenceBlock, _chrominanceTransformFactors, blueDifferencePredictor, _chrominanceDcHuffmanTable, _chrominanceAcHuffmanTable);
          redDifferencePredictor = _encodeDataUnit(output, redDifferenceBlock, _chrominanceTransformFactors, redDifferencePredictor, _chrominanceDcHuffmanTable, _chrominanceAcHuffmanTable);
        }
      }
    } else {
      // 4:2:0 chroma: process 8x8 blocks and prepare subsampled U and V.
      final List<Float32List> luminanceBlocks = List<Float32List>.generate(4, (_) => Float32List(64));
      final List<Float32List> blueDifferenceBlocks = List<Float32List>.generate(4, (_) => Float32List(64));
      final List<Float32List> redDifferenceBlocks = List<Float32List>.generate(4, (_) => Float32List(64));
      final Float32List downsampledBlueDifference = Float32List(64);
      final Float32List downsampledRedDifference = Float32List(64);

      for (int y = 0; y < height; y += 16) {
        for (int x = 0; x < width; x += 16) {
          _convertBlockToYuv(
            image.bytes,
            x,
            y,
            width,
            height,
            luminanceBlocks[0],
            blueDifferenceBlocks[0],
            redDifferenceBlocks[0],
          );
          _convertBlockToYuv(
            image.bytes,
            x + 8,
            y,
            width,
            height,
            luminanceBlocks[1],
            blueDifferenceBlocks[1],
            redDifferenceBlocks[1],
          );
          _convertBlockToYuv(
            image.bytes,
            x,
            y + 8,
            width,
            height,
            luminanceBlocks[2],
            blueDifferenceBlocks[2],
            redDifferenceBlocks[2],
          );
          _convertBlockToYuv(
            image.bytes,
            x + 8,
            y + 8,
            width,
            height,
            luminanceBlocks[3],
            blueDifferenceBlocks[3],
            redDifferenceBlocks[3],
          );
          _downsampleChromaBlocks(downsampledBlueDifference, blueDifferenceBlocks[0], blueDifferenceBlocks[1], blueDifferenceBlocks[2], blueDifferenceBlocks[3]);
          _downsampleChromaBlocks(downsampledRedDifference, redDifferenceBlocks[0], redDifferenceBlocks[1], redDifferenceBlocks[2], redDifferenceBlocks[3]);
          for (final Float32List luminanceBlock in luminanceBlocks) {
            luminancePredictor = _encodeDataUnit(output, luminanceBlock, _luminanceTransformFactors, luminancePredictor, _luminanceDcHuffmanTable, _luminanceAcHuffmanTable);
          }
          blueDifferencePredictor = _encodeDataUnit(output, downsampledBlueDifference, _chrominanceTransformFactors, blueDifferencePredictor, _chrominanceDcHuffmanTable, _chrominanceAcHuffmanTable);
          redDifferencePredictor = _encodeDataUnit(output, downsampledRedDifference, _chrominanceTransformFactors, redDifferencePredictor, _chrominanceDcHuffmanTable, _chrominanceAcHuffmanTable);
        }
      }
    }

    _finishScan(output);
    return output.takeBytes();
  }

  /// Transforms and quantizes a band while leaving entropy coding for the
  /// parent isolate, where direct-current predictors and output bits remain in
  /// global scan order.
  _JpegBandResult _transformBand(
    Uint8List pixels, {
    required int width,
    required int height,
  }) {
    final int mcuWidth = chroma == JpegChroma.yuv444 ? 8 : 16;
    final int mcuHeight = mcuWidth;
    final int blocksPerMcu = chroma == JpegChroma.yuv444 ? 3 : 6;
    final int mcuColumnCount = (width + mcuWidth - 1) ~/ mcuWidth;
    final int mcuRowCount = (height + mcuHeight - 1) ~/ mcuHeight;
    final Int16List coefficients = Int16List(mcuColumnCount * mcuRowCount * blocksPerMcu * 64);
    int destination = 0;

    if (chroma == JpegChroma.yuv444) {
      final Float32List luminanceBlock = Float32List(64);
      final Float32List blueDifferenceBlock = Float32List(64);
      final Float32List redDifferenceBlock = Float32List(64);
      for (int y = 0; y < height; y += 8) {
        for (int x = 0; x < width; x += 8) {
          _convertBlockToYuv(
            pixels,
            x,
            y,
            width,
            height,
            luminanceBlock,
            blueDifferenceBlock,
            redDifferenceBlock,
          );
          destination = _appendTransformedBlock(
            coefficients,
            destination,
            luminanceBlock,
            _luminanceTransformFactors,
          );
          destination = _appendTransformedBlock(
            coefficients,
            destination,
            blueDifferenceBlock,
            _chrominanceTransformFactors,
          );
          destination = _appendTransformedBlock(
            coefficients,
            destination,
            redDifferenceBlock,
            _chrominanceTransformFactors,
          );
        }
      }
    } else {
      final List<Float32List> luminanceBlocks = List<Float32List>.generate(4, (_) => Float32List(64));
      final List<Float32List> blueDifferenceBlocks = List<Float32List>.generate(4, (_) => Float32List(64));
      final List<Float32List> redDifferenceBlocks = List<Float32List>.generate(4, (_) => Float32List(64));
      final Float32List downsampledBlueDifference = Float32List(64);
      final Float32List downsampledRedDifference = Float32List(64);
      for (int y = 0; y < height; y += 16) {
        for (int x = 0; x < width; x += 16) {
          _convertBlockToYuv(pixels, x, y, width, height, luminanceBlocks[0], blueDifferenceBlocks[0], redDifferenceBlocks[0]);
          _convertBlockToYuv(pixels, x + 8, y, width, height, luminanceBlocks[1], blueDifferenceBlocks[1], redDifferenceBlocks[1]);
          _convertBlockToYuv(pixels, x, y + 8, width, height, luminanceBlocks[2], blueDifferenceBlocks[2], redDifferenceBlocks[2]);
          _convertBlockToYuv(pixels, x + 8, y + 8, width, height, luminanceBlocks[3], blueDifferenceBlocks[3], redDifferenceBlocks[3]);
          _downsampleChromaBlocks(
            downsampledBlueDifference,
            blueDifferenceBlocks[0],
            blueDifferenceBlocks[1],
            blueDifferenceBlocks[2],
            blueDifferenceBlocks[3],
          );
          _downsampleChromaBlocks(
            downsampledRedDifference,
            redDifferenceBlocks[0],
            redDifferenceBlocks[1],
            redDifferenceBlocks[2],
            redDifferenceBlocks[3],
          );
          for (final Float32List luminanceBlock in luminanceBlocks) {
            destination = _appendTransformedBlock(
              coefficients,
              destination,
              luminanceBlock,
              _luminanceTransformFactors,
            );
          }
          destination = _appendTransformedBlock(
            coefficients,
            destination,
            downsampledBlueDifference,
            _chrominanceTransformFactors,
          );
          destination = _appendTransformedBlock(
            coefficients,
            destination,
            downsampledRedDifference,
            _chrominanceTransformFactors,
          );
        }
      }
    }
    return _JpegBandResult(coefficients: coefficients);
  }

  /// Appends one transformed block in JPEG zigzag order.
  int _appendTransformedBlock(
    Int16List output,
    int destination,
    Float32List block,
    Float32List transformFactors,
  ) {
    final Int32List quantized = _transformAndQuantize(block, transformFactors);
    for (int naturalIndex = 0; naturalIndex < 64; naturalIndex++) {
      output[destination + jpegNaturalToZigZagOrder[naturalIndex]] = quantized[naturalIndex];
    }
    return destination + 64;
  }

  /// Entropy-encodes transformed bands in their original scan order.
  Uint8List _encodeTransformedBands(
    List<_JpegBandResult> bands, {
    required int width,
    required int height,
  }) {
    final OutputBuffer output = OutputBuffer(bigEndian: true);
    _writeSegments(output, width, height);
    _resetBits();
    int luminancePredictor = 0;
    int blueDifferencePredictor = 0;
    int redDifferencePredictor = 0;
    final int blocksPerMcu = chroma == JpegChroma.yuv444 ? 3 : 6;
    final int luminanceBlockCount = chroma == JpegChroma.yuv444 ? 1 : 4;
    int blockIndex = 0;

    for (final _JpegBandResult band in bands) {
      final Int16List coefficients = band.coefficients;
      for (int base = 0; base < coefficients.length; base += 64) {
        int lastNonZeroPosition = 63;
        while (lastNonZeroPosition > 0 && coefficients[base + lastNonZeroPosition] == 0) {
          lastNonZeroPosition--;
        }
        final int component = blockIndex % blocksPerMcu;
        if (component < luminanceBlockCount) {
          luminancePredictor = _encodeZigzagBlock(
            output,
            coefficients,
            base,
            lastNonZeroPosition,
            luminancePredictor,
            _luminanceDcHuffmanTable,
            _luminanceAcHuffmanTable,
          );
        } else if (component == luminanceBlockCount) {
          blueDifferencePredictor = _encodeZigzagBlock(
            output,
            coefficients,
            base,
            lastNonZeroPosition,
            blueDifferencePredictor,
            _chrominanceDcHuffmanTable,
            _chrominanceAcHuffmanTable,
          );
        } else {
          redDifferencePredictor = _encodeZigzagBlock(
            output,
            coefficients,
            base,
            lastNonZeroPosition,
            redDifferencePredictor,
            _chrominanceDcHuffmanTable,
            _chrominanceAcHuffmanTable,
          );
        }
        blockIndex++;
      }
    }
    _finishScan(output);
    return output.takeBytes();
  }

  /// Converts one 8 by 8 RGBA block to centered Y, U, and V samples.
  void _convertBlockToYuv(
    Uint8List pixels,
    int x,
    int y,
    int width,
    int height,
    Float32List luminanceBlock,
    Float32List blueDifferenceBlock,
    Float32List redDifferenceBlock,
  ) {
    for (int coefficientIndex = 0; coefficientIndex < 64; coefficientIndex++) {
      final int row = coefficientIndex >> 3;
      final int column = coefficientIndex & 7;

      int sourceY = y + row;
      int sourceX = x + column;

      if (sourceY >= height) {
        sourceY -= y + 1 + row - height;
      }

      if (sourceX >= width) {
        sourceX -= (x + column) - width + 1;
      }

      final int offset = (sourceY * width + sourceX) * 4;
      final int alpha = pixels[offset + 3];
      final int inverseAlpha = 255 - alpha;
      final int red = (pixels[offset] * alpha + 255 * inverseAlpha + 127) ~/ 255;
      final int green = (pixels[offset + 1] * alpha + 255 * inverseAlpha + 127) ~/ 255;
      final int blue = (pixels[offset + 2] * alpha + 255 * inverseAlpha + 127) ~/ 255;

      luminanceBlock[coefficientIndex] = ((_rgbToYuvTable[red] + _rgbToYuvTable[green + 256] + _rgbToYuvTable[blue + 512]) >> 16) - 128.0;
      blueDifferenceBlock[coefficientIndex] = ((_rgbToYuvTable[red + 768] + _rgbToYuvTable[green + 1024] + _rgbToYuvTable[blue + 1280]) >> 16) - 128.0;
      redDifferenceBlock[coefficientIndex] = ((_rgbToYuvTable[red + 1280] + _rgbToYuvTable[green + 1536] + _rgbToYuvTable[blue + 1792]) >> 16) - 128.0;
    }
  }

  /// Downsamples four chroma blocks into one block using 2 by 2 averages.
  void _downsampleChromaBlocks(
    Float32List outputBlock,
    Float32List upperLeftBlock,
    Float32List upperRightBlock,
    Float32List lowerLeftBlock,
    Float32List lowerRightBlock,
  ) {
    for (int outputIndex = 0; outputIndex < 64; outputIndex++) {
      final Float32List sourceBlock = outputIndex < 32
          ? outputIndex % 8 < 4
                ? upperLeftBlock
                : upperRightBlock
          : outputIndex % 8 < 4
          ? lowerLeftBlock
          : lowerRightBlock;
      final int sourceIndex = (((outputIndex % 32) ~/ 8) << 4) + ((outputIndex % 4) << 1);
      outputBlock[outputIndex] = (sourceBlock[sourceIndex] + sourceBlock[sourceIndex + 1] + sourceBlock[sourceIndex + 8] + sourceBlock[sourceIndex + 9]) / 4;
    }
  }

  /// Writes a two-byte JPEG marker.
  void _writeMarker(OutputBuffer fp, int marker) {
    fp
      ..writeByte(0xff)
      ..writeByte(marker & 0xff);
  }

  /// Builds quality-scaled luminance and chrominance quantization tables.
  void _initQuantTables(int scaleFactor) {
    const luminanceBaseTable = <int>[
      16,
      11,
      10,
      16,
      24,
      40,
      51,
      61,
      12,
      12,
      14,
      19,
      26,
      58,
      60,
      55,
      14,
      13,
      16,
      24,
      40,
      57,
      69,
      56,
      14,
      17,
      22,
      29,
      51,
      87,
      80,
      62,
      18,
      22,
      37,
      56,
      68,
      109,
      103,
      77,
      24,
      35,
      55,
      64,
      81,
      104,
      113,
      92,
      49,
      64,
      78,
      87,
      103,
      121,
      120,
      101,
      72,
      92,
      95,
      98,
      112,
      100,
      103,
      99,
    ];

    for (int i = 0; i < 64; i++) {
      int t = ((luminanceBaseTable[i] * scaleFactor + 50) / 100).floor();
      if (t < 1) {
        t = 1;
      } else if (t > 255) {
        t = 255;
      }
      _yTable[jpegNaturalToZigZagOrder[i]] = t;
    }

    const chrominanceBaseTable = <int>[
      17,
      18,
      24,
      47,
      99,
      99,
      99,
      99,
      18,
      21,
      26,
      66,
      99,
      99,
      99,
      99,
      24,
      26,
      56,
      99,
      99,
      99,
      99,
      99,
      47,
      66,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
      99,
    ];

    for (int j = 0; j < 64; j++) {
      int u = ((chrominanceBaseTable[j] * scaleFactor + 50) / 100).floor();
      if (u < 1) {
        u = 1;
      } else if (u > 255) {
        u = 255;
      }
      _uvTable[jpegNaturalToZigZagOrder[j]] = u;
    }

    const aasf = <double>[1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379];

    int k = 0;
    for (int row = 0; row < 8; row++) {
      for (int col = 0; col < 8; col++) {
        _luminanceTransformFactors[k] = 1.0 / (_yTable[jpegNaturalToZigZagOrder[k]] * aasf[row] * aasf[col] * 8.0);
        _chrominanceTransformFactors[k] = 1.0 / (_uvTable[jpegNaturalToZigZagOrder[k]] * aasf[row] * aasf[col] * 8.0);
        k++;
      }
    }
  }

  /// Initializes the four baseline luminance and chrominance Huffman tables.
  void _initHuffmanTable() {
    _luminanceDcHuffmanTable = JpegHuffmanCodeTable.fromDefinition(
      countsByBitLength: _standardLuminanceDcCodeCounts,
      symbols: _standardLuminanceDcValues,
    );
    _chrominanceDcHuffmanTable = JpegHuffmanCodeTable.fromDefinition(
      countsByBitLength: _standardChrominanceDcCodeCounts,
      symbols: _standardChrominanceDcValues,
    );
    _luminanceAcHuffmanTable = JpegHuffmanCodeTable.fromDefinition(
      countsByBitLength: _standardLuminanceAcCodeCounts,
      symbols: _standardLuminanceAcValues,
    );
    _chrominanceAcHuffmanTable = JpegHuffmanCodeTable.fromDefinition(
      countsByBitLength: _standardChrominanceAcCodeCounts,
      symbols: _standardChrominanceAcValues,
    );
  }

  /// Precomputes fixed-point RGB-to-YUV conversion products.
  void _initRgbYuvTable() {
    for (int i = 0; i < 256; i++) {
      _rgbToYuvTable[i] = 19595 * i;
      _rgbToYuvTable[(i + 256)] = 38470 * i;
      _rgbToYuvTable[(i + 512)] = 7471 * i + 0x8000;
      _rgbToYuvTable[(i + 768)] = -11059 * i;
      _rgbToYuvTable[(i + 1024)] = -21709 * i;
      _rgbToYuvTable[(i + 1280)] = 32768 * i + 0x807FFF;
      _rgbToYuvTable[(i + 1536)] = -27439 * i;
      _rgbToYuvTable[(i + 1792)] = -5329 * i;
    }
  }

  /// Applies the forward discrete cosine transform and quantizes one block.
  Int32List _transformAndQuantize(Float32List data, Float32List transformFactors) {
    // Pass 1: process rows.
    int dataOffset = 0;
    for (int i = 0; i < 8; ++i) {
      final double d0 = data[dataOffset];
      final double d1 = data[dataOffset + 1];
      final double d2 = data[dataOffset + 2];
      final double d3 = data[dataOffset + 3];
      final double d4 = data[dataOffset + 4];
      final double d5 = data[dataOffset + 5];
      final double d6 = data[dataOffset + 6];
      final double d7 = data[dataOffset + 7];

      final double tmp0 = d0 + d7;
      final double tmp7 = d0 - d7;
      final double tmp1 = d1 + d6;
      final double tmp6 = d1 - d6;
      final double tmp2 = d2 + d5;
      final double tmp5 = d2 - d5;
      final double tmp3 = d3 + d4;
      final double tmp4 = d3 - d4;

      // Even part
      double tmp10 = tmp0 + tmp3; // phase 2
      final double tmp13 = tmp0 - tmp3;
      double tmp11 = tmp1 + tmp2;
      double tmp12 = tmp1 - tmp2;

      data[dataOffset] = tmp10 + tmp11; // phase 3
      data[dataOffset + 4] = tmp10 - tmp11;

      final double z1 = (tmp12 + tmp13) * 0.707106781; // c4
      data[dataOffset + 2] = tmp13 + z1; // phase 5
      data[dataOffset + 6] = tmp13 - z1;

      // Odd part
      tmp10 = tmp4 + tmp5; // phase 2
      tmp11 = tmp5 + tmp6;
      tmp12 = tmp6 + tmp7;

      // The rotator is modified from fig 4-8 to avoid extra negations.
      final double z5 = (tmp10 - tmp12) * 0.382683433; // c6
      final double z2 = 0.541196100 * tmp10 + z5; // c2 - c6
      final double z4 = 1.306562965 * tmp12 + z5; // c2 + c6
      final double z3 = tmp11 * 0.707106781; // c4

      final double z11 = tmp7 + z3; // phase 5
      final double z13 = tmp7 - z3;

      data[dataOffset + 5] = z13 + z2; // phase 6
      data[dataOffset + 3] = z13 - z2;
      data[dataOffset + 1] = z11 + z4;
      data[dataOffset + 7] = z11 - z4;

      dataOffset += 8; // advance pointer to next row
    }

    // Pass 2: process columns.
    dataOffset = 0;
    for (int i = 0; i < 8; ++i) {
      final double d0 = data[dataOffset];
      final double d1 = data[dataOffset + 8];
      final double d2 = data[dataOffset + 16];
      final double d3 = data[dataOffset + 24];
      final double d4 = data[dataOffset + 32];
      final double d5 = data[dataOffset + 40];
      final double d6 = data[dataOffset + 48];
      final double d7 = data[dataOffset + 56];

      final double tmp0p2 = d0 + d7;
      final double tmp7p2 = d0 - d7;
      final double tmp1p2 = d1 + d6;
      final double tmp6p2 = d1 - d6;
      final double tmp2p2 = d2 + d5;
      final double tmp5p2 = d2 - d5;
      final double tmp3p2 = d3 + d4;
      final double tmp4p2 = d3 - d4;

      // Even part
      double tmp10p2 = tmp0p2 + tmp3p2; // phase 2
      final double tmp13p2 = tmp0p2 - tmp3p2;
      double tmp11p2 = tmp1p2 + tmp2p2;
      double tmp12p2 = tmp1p2 - tmp2p2;

      data[dataOffset] = tmp10p2 + tmp11p2; // phase 3
      data[dataOffset + 32] = tmp10p2 - tmp11p2;

      final double z1p2 = (tmp12p2 + tmp13p2) * 0.707106781; // c4
      data[dataOffset + 16] = tmp13p2 + z1p2; // phase 5
      data[dataOffset + 48] = tmp13p2 - z1p2;

      // Odd part
      tmp10p2 = tmp4p2 + tmp5p2; // phase 2
      tmp11p2 = tmp5p2 + tmp6p2;
      tmp12p2 = tmp6p2 + tmp7p2;

      // The rotator is modified from fig 4-8 to avoid extra negations.
      final double z5p2 = (tmp10p2 - tmp12p2) * 0.382683433; // c6
      final double z2p2 = 0.541196100 * tmp10p2 + z5p2; // c2 - c6
      final double z4p2 = 1.306562965 * tmp12p2 + z5p2; // c2 + c6
      final double z3p2 = tmp11p2 * 0.707106781; // c4

      final double z11p2 = tmp7p2 + z3p2; // phase 5
      final double z13p2 = tmp7p2 - z3p2;

      data[dataOffset + 40] = z13p2 + z2p2; // phase 6
      data[dataOffset + 24] = z13p2 - z2p2;
      data[dataOffset + 8] = z11p2 + z4p2;
      data[dataOffset + 56] = z11p2 - z4p2;

      dataOffset++; // advance pointer to next column
    }

    // Quantize/descale the coefficients
    for (int i = 0; i < 64; ++i) {
      // Apply the quantization and scaling factor & Round to nearest integer
      final double transformedCoefficient = data[i] * transformFactors[i];
      _quantizedCoefficients[i] = (transformedCoefficient > 0.0) ? ((transformedCoefficient + 0.5).toInt()) : ((transformedCoefficient - 0.5).toInt());
    }

    return _quantizedCoefficients;
  }

  /// Writes the JFIF application header.
  void _writeApplicationSegment(OutputBuffer out) {
    _writeMarker(out, JpegMarker.application0);
    out
      ..writeUint16(16) // length
      ..writeByte(0x4A) // J
      ..writeByte(0x46) // F
      ..writeByte(0x49) // I
      ..writeByte(0x46) // F
      ..writeByte(0) // '\0'
      ..writeByte(1) // versionhi
      ..writeByte(1) // versionlo
      ..writeByte(0) // xyunits
      ..writeUint16(1) // xdensity
      ..writeUint16(1) // ydensity
      ..writeByte(0) // thumbnwidth
      ..writeByte(0); // thumbnheight
  }

  /// Writes the baseline frame header and chroma sampling factors.
  void _writeStartOfFrameSegment(OutputBuffer out, int width, int height, JpegChroma chroma) {
    _writeMarker(out, JpegMarker.startOfFrameBaseline);
    out
      ..writeUint16(17) // length, truecolor YUV JPG
      ..writeByte(8) // precision
      ..writeUint16(height)
      ..writeUint16(width)
      ..writeByte(3) // nrofcomponents
      ..writeByte(1) // IdY
      ..writeByte(chroma == JpegChroma.yuv444 ? 0x11 : 0x22) // HVY
      ..writeByte(0) // QTY
      ..writeByte(2) // IdU
      ..writeByte(0x11) // HVU
      ..writeByte(1) // QTU
      ..writeByte(3) // IdV
      ..writeByte(0x11) // HVV
      ..writeByte(1); // QTV
  }

  /// Writes luminance and chrominance quantization tables.
  void _writeQuantizationTables(OutputBuffer out) {
    _writeMarker(out, JpegMarker.defineQuantizationTable);
    out
      ..writeUint16(132) // length
      ..writeByte(0);
    for (int i = 0; i < 64; i++) {
      out.writeByte(_yTable[i]);
    }
    out.writeByte(1);
    for (int j = 0; j < 64; j++) {
      out.writeByte(_uvTable[j]);
    }
  }

  /// Writes the standard baseline Huffman tables.
  void _writeHuffmanTables(OutputBuffer out) {
    _writeMarker(out, JpegMarker.defineHuffmanTable);
    out
      ..writeUint16(0x01A2) // length
      ..writeByte(0); // HTYDCinfo
    for (int i = 0; i < 16; i++) {
      out.writeByte(_standardLuminanceDcCodeCounts[i + 1]);
    }
    for (int j = 0; j <= 11; j++) {
      out.writeByte(_standardLuminanceDcValues[j]);
    }

    out.writeByte(0x10); // HTYACinfo
    for (int k = 0; k < 16; k++) {
      out.writeByte(_standardLuminanceAcCodeCounts[k + 1]);
    }
    for (int l = 0; l <= 161; l++) {
      out.writeByte(_standardLuminanceAcValues[l]);
    }

    out.writeByte(1); // HTUDCinfo
    for (int m = 0; m < 16; m++) {
      out.writeByte(_standardChrominanceDcCodeCounts[m + 1]);
    }
    for (int n = 0; n <= 11; n++) {
      out.writeByte(_standardChrominanceDcValues[n]);
    }

    out.writeByte(0x11); // HTUACinfo
    for (int o = 0; o < 16; o++) {
      out.writeByte(_standardChrominanceAcCodeCounts[o + 1]);
    }
    for (int p = 0; p <= 161; p++) {
      out.writeByte(_standardChrominanceAcValues[p]);
    }
  }

  /// Writes the start-of-scan header for the three color components.
  void _writeStartOfScanSegment(OutputBuffer out) {
    _writeMarker(out, JpegMarker.startOfScan);
    out
      ..writeUint16(12) // length
      ..writeByte(3) // nrofcomponents
      ..writeByte(1) // IdY
      ..writeByte(0) // HTY
      ..writeByte(2) // IdU
      ..writeByte(0x11) // HTU
      ..writeByte(3) // IdV
      ..writeByte(0x11) // HTV
      ..writeByte(0) // Ss
      ..writeByte(0x3f) // Se
      ..writeByte(0); // Bf
  }

  /// Transforms and entropy-encodes one data unit, returning its DC value.
  int _encodeDataUnit(
    OutputBuffer out,
    Float32List coefficients,
    Float32List transformFactors,
    int previousDcCoefficient,
    JpegHuffmanCodeTable dcHuffmanTable,
    JpegHuffmanCodeTable acHuffmanTable,
  ) {
    final Int32List quantizedCoefficients = _transformAndQuantize(coefficients, transformFactors);
    for (int j = 0; j < 64; ++j) {
      _zigzagCoefficients[jpegNaturalToZigZagOrder[j]] = quantizedCoefficients[j];
    }
    int lastNonZeroPosition = 63;
    for (; lastNonZeroPosition > 0 && _zigzagCoefficients[lastNonZeroPosition] == 0; lastNonZeroPosition--) {}
    return _encodeZigzagBlock(out, _zigzagCoefficients, 0, lastNonZeroPosition, previousDcCoefficient, dcHuffmanTable, acHuffmanTable);
  }

  /// Writes one zigzag-ordered block from [_zigzagCoefficients].
  ///
  /// Kept separate from the transform so that the transform, which is
  /// independent per block, can run elsewhere while entropy coding stays
  /// sequential: the direct-current term is differential across the whole
  /// scan, and the bit stream is written in order.
  int _encodeZigzagBlock(
    OutputBuffer out,
    Int16List block,
    int base,
    int lastNonZeroPosition,
    int previousDcCoefficient,
    JpegHuffmanCodeTable dcHuffmanTable,
    JpegHuffmanCodeTable acHuffmanTable,
  ) {
    final int currentDcCoefficient = block[base];
    final int dcDifference = currentDcCoefficient - previousDcCoefficient;
    final int dcMagnitudeBitCount = jpegMagnitudeBitCount(dcDifference);
    _writeHuffmanSymbol(out, dcHuffmanTable, dcMagnitudeBitCount);
    if (dcMagnitudeBitCount != 0) {
      _writeBits(out, jpegMagnitudeValue(dcDifference, dcMagnitudeBitCount), dcMagnitudeBitCount);
    }

    // Encode ACs
    //lastNonZeroPosition = first element in reverse order !=0
    if (lastNonZeroPosition == 0) {
      _writeHuffmanSymbol(out, acHuffmanTable, 0x00);
      return currentDcCoefficient;
    }

    int i = 1;
    int runCount;
    while (i <= lastNonZeroPosition) {
      final int startPosition = i;
      for (; (block[base + i] == 0) && (i <= lastNonZeroPosition); ++i) {}

      int zeroCount = i - startPosition;
      if (zeroCount >= 16) {
        runCount = zeroCount >> 4;
        for (int markerIndex = 1; markerIndex <= runCount; ++markerIndex) {
          _writeHuffmanSymbol(out, acHuffmanTable, 0xf0);
        }
        zeroCount = zeroCount & 0xF;
      }
      final int coefficient = block[base + i];
      final int magnitudeBitCount = jpegMagnitudeBitCount(coefficient);
      _writeHuffmanSymbol(out, acHuffmanTable, (zeroCount << 4) + magnitudeBitCount);
      _writeBits(out, jpegMagnitudeValue(coefficient, magnitudeBitCount), magnitudeBitCount);
      i++;
    }

    if (lastNonZeroPosition != 63) {
      _writeHuffmanSymbol(out, acHuffmanTable, 0x00);
    }

    return currentDcCoefficient;
  }

  /// Writes [symbol] using its canonical entry in [table].
  void _writeHuffmanSymbol(OutputBuffer output, JpegHuffmanCodeTable table, int symbol) {
    _writeBits(output, table.codes[symbol], table.bitLengths[symbol]);
  }

  /// Appends [bitCount] high-to-low bits while applying JPEG byte stuffing.
  void _writeBits(OutputBuffer out, int value, int bitCount) {
    if (bitCount == 0) {
      return;
    }
    int pending = bitCount;
    while (pending > 0) {
      final int taken = pending <= _bytePos + 1 ? pending : _bytePos + 1;
      pending -= taken;
      _byteNew |= ((value >>> pending) & ((1 << taken) - 1)) << (_bytePos + 1 - taken);
      _bytePos -= taken;
      if (_bytePos < 0) {
        if (_byteNew == 0xff) {
          out
            ..writeByte(0xff)
            ..writeByte(0);
        } else {
          out.writeByte(_byteNew);
        }
        _bytePos = 7;
        _byteNew = 0;
      }
    }
  }

  /// Resets the entropy bit accumulator to an empty byte.
  void _resetBits() {
    _byteNew = 0;
    _bytePos = 7;
  }
}
