import 'dart:typed_data';

import 'package:imcodec/src/codecs/encoder.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/output_buffer.dart';

/// Encodes images as lossless WebP data.
///
/// Uses the VP8L lossless bitstream format wrapped in a RIFF/WebP container.
/// Applies the subtract-green transform and LZ77 back-references.
final class WebPEncoder extends Encoder {
  /// Maps nearby two-dimensional pixel offsets to VP8L distance plane codes.
  static const List<int> _distancePlaneLookup = <int>[
    // yoffset=0 (xoffset 8..1, then 0..-7 which are unused=255)
    96, 73, 55, 39, 23, 13, 5, 1, 255, 255, 255, 255, 255, 255, 255, 255,
    // yoffset=1
    101, 78, 58, 42, 26, 16, 8, 2, 0, 3, 9, 17, 27, 43, 59, 79,
    // yoffset=2
    102, 86, 62, 46, 32, 20, 10, 6, 4, 7, 11, 21, 33, 47, 63, 87,
    // yoffset=3
    105, 90, 70, 52, 37, 28, 18, 14, 12, 15, 19, 29, 38, 53, 71, 91,
    // yoffset=4
    110, 99, 82, 66, 48, 35, 30, 24, 22, 25, 31, 36, 49, 67, 83, 100,
    // yoffset=5
    115, 108, 94, 76, 64, 50, 44, 40, 34, 41, 45, 51, 65, 77, 95, 109,
    // yoffset=6
    118, 113, 103, 92, 80, 68, 60, 56, 54, 57, 61, 69, 81, 93, 104, 114,
    // yoffset=7
    119, 116, 111, 106, 97, 88, 84, 74, 72, 75, 85, 89, 98, 107, 112, 117,
  ];

  /// Creates a lossless WebP encoder.
  const WebPEncoder();

  @override
  Uint8List encode(Image image, {bool singleFrame = false}) {
    final int width = image.width;
    final int height = image.height;

    final Uint8List vp8lData = _encodeVp8l(
      image: image,
      width: width,
      height: height,
    );

    // Wrap in RIFF/WebP container
    final OutputBuffer output = OutputBuffer();
    final int paddedLength = vp8lData.length + (vp8lData.length.isOdd ? 1 : 0);
    final int fileSize = 4 /* 'WEBP' */ + 8 /* 'VP8L' + chunk size */ + paddedLength;
    output
      ..writeBytes(_encodeRiffTag(value: 'RIFF'))
      ..writeUint32(fileSize)
      ..writeBytes(_encodeRiffTag(value: 'WEBP'))
      ..writeBytes(_encodeRiffTag(value: 'VP8L'))
      ..writeUint32(vp8lData.length)
      ..writeBytes(vp8lData);
    if (vp8lData.length.isOdd) {
      output.writeByte(0);
    }

    return output.getBytes();
  }

  /// Encodes [image] as a raw VP8L lossless bitstream.
  Uint8List _encodeVp8l({
    required Image image,
    required int width,
    required int height,
  }) {
    final OutputBuffer output = OutputBuffer();

    // VP8L image header: signature byte 0x2f + 28-bit header (w-1, h-1,
    // alpha_is_used, version=0) packed little-endian.
    final bool hasAlpha = image.numChannels >= 4;
    final int header = (width - 1) | ((height - 1) << 14) | ((hasAlpha ? 1 : 0) << 28);
    output
      ..writeByte(0x2f)
      ..writeByte(header & 0xff)
      ..writeByte((header >> 8) & 0xff)
      ..writeByte((header >> 16) & 0xff)
      ..writeByte((header >> 24) & 0xff);

    // Collect pixel data first (needed for predictor mode selection).
    const int predictorSizeBits = 5;
    const int predictorBlockSize = 1 << predictorSizeBits;
    final int predictorBlockWidth = (width + predictorBlockSize - 1) ~/ predictorBlockSize;
    final int predictorBlockHeight = (height + predictorBlockSize - 1) ~/ predictorBlockSize;
    final int pixelCount = width * height;
    final Uint8List green = Uint8List(pixelCount);
    final Uint8List red = Uint8List(pixelCount);
    final Uint8List blue = Uint8List(pixelCount);
    final Uint8List alpha = Uint8List(pixelCount);

    for (int pixelIndex = 0; pixelIndex < pixelCount; pixelIndex++) {
      final int offset = pixelIndex * 4;
      red[pixelIndex] = image.bytes[offset];
      green[pixelIndex] = image.bytes[offset + 1];
      blue[pixelIndex] = image.bytes[offset + 2];
      alpha[pixelIndex] = image.bytes[offset + 3];
    }

    // Apply Subtract Green Transform
    _applySubtractGreenTransform(
      red: red,
      green: green,
      blue: blue,
      pixelCount: pixelCount,
    );

    // Choose best predictor mode per 32×32 block.
    // This is done on the subtracted data.
    final List<int> predictorModes = _selectPredictorModes(
      red: red,
      green: green,
      blue: blue,
      alpha: alpha,
      width: width,
      height: height,
      blockWidth: predictorBlockWidth,
      blockHeight: predictorBlockHeight,
      blockSize: predictorBlockSize,
    );

    // Apply Predictor Transform
    _applyPredictorTransform(
      red: red,
      green: green,
      blue: blue,
      alpha: alpha,
      width: width,
      height: height,
      blockWidth: predictorBlockWidth,
      blockSize: predictorBlockSize,
      modes: predictorModes,
    );

    final _Vp8lBitWriter bitWriter = _Vp8lBitWriter()
      // Write Subtract Green Transform
      ..writeBits(1, 1) // has_transform = 1
      ..writeBits(2, 2) // transform_type = 2 (SUBTRACT_GREEN)
      // Write Predictor Transform
      ..writeBits(1, 1) // has_transform = 1
      ..writeBits(0, 2) // transform_type = 0 (PREDICTOR)
      ..writeBits(predictorSizeBits - 2, 3);
    _writePredictorSubImage(
      bitWriter: bitWriter,
      blockWidth: predictorBlockWidth,
      blockHeight: predictorBlockHeight,
      modes: predictorModes,
    );

    // Finish transforms
    bitWriter
      ..writeBits(0, 1) // has_transform = 0
      ..writeBits(0, 1) // no color cache
      ..writeBits(0, 1); // no meta Huffman codes

    // Tokenize into literals and LZ77 back-references using a hash chain.
    // Token encoding:
    //   literalAt: list of pixel indices for literal tokens
    //   copyLen/copyDist: parallel lists for back-reference length and distance
    //   isLit: bool array indexed by token order
    final List<bool> literalTokens = <bool>[];
    final List<int> literalPixelIndices = <int>[];
    final List<int> copyLengths = <int>[];
    final List<int> copyDistances = <int>[];

    // Hash table: RGBA key → recent positions (newest first, up to maxChain).
    const int maximumChainLength = 64;
    const int maximumMatchLength = 4096;
    final Map<int, List<int>> hashChain = <int, List<int>>{};

    void addToHash(int position) {
      final int key = (green[position] << 24) | (red[position] << 16) | (blue[position] << 8) | alpha[position];
      final List<int> list = hashChain.putIfAbsent(key, () => <int>[]);
      if (list.length >= maximumChainLength) {
        list.removeAt(0);
      }
      list.add(position);
    }

    int pixelIndex = 0;
    while (pixelIndex < pixelCount) {
      // Build RGBA key for current position.
      final int key = (green[pixelIndex] << 24) | (red[pixelIndex] << 16) | (blue[pixelIndex] << 8) | alpha[pixelIndex];

      // Search for best match.
      int bestLength = 0;
      int bestDistance = 0;
      final List<int>? candidates = hashChain[key];
      if (pixelIndex > 0 && candidates != null) {
        for (int ci = candidates.length - 1; ci >= 0; ci--) {
          final int candidateIndex = candidates[ci];
          final int distance = pixelIndex - candidateIndex;

          // VP8L spec limits max distance to 1048576.
          // The first 120 values are reserved, so the actual
          // maximum distance is 1048576 - 120 offset = 1048456
          // https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification#522_lz77_backward_reference
          if (distance > 1048456) {
            break;
          }

          // Extend the match forward.
          int matchLength = 1;
          while (matchLength < maximumMatchLength &&
              pixelIndex + matchLength < pixelCount &&
              green[pixelIndex + matchLength] == green[candidateIndex + matchLength] &&
              red[pixelIndex + matchLength] == red[candidateIndex + matchLength] &&
              blue[pixelIndex + matchLength] == blue[candidateIndex + matchLength] &&
              alpha[pixelIndex + matchLength] == alpha[candidateIndex + matchLength]) {
            matchLength++;
          }
          if (matchLength > bestLength || (matchLength == bestLength && distance < bestDistance)) {
            bestLength = matchLength;
            bestDistance = distance;
          }
        }
      }

      if (bestLength >= 3) {
        literalTokens.add(false);
        copyLengths.add(bestLength);
        copyDistances.add(bestDistance);
        // Add all covered positions to hash (enables future matches into this
        // region). Only add if we have space; skip the last position to avoid
        // self-referential additions.
        for (int k = 0; k < bestLength; k++) {
          addToHash(pixelIndex + k);
        }
        pixelIndex += bestLength;
      } else {
        literalTokens.add(true);
        literalPixelIndices.add(pixelIndex);
        addToHash(pixelIndex);
        pixelIndex++;
      }
    }

    // Build frequency tables. VP8L uses 5 Huffman code groups:
    //   Group 0 (green): 280 symbols (256 literals + 24 LZ77 length codes)
    //   Group 1 (red):   256 symbols (r' after subtract-green transform)
    //   Group 2 (blue):  256 symbols (b' after subtract-green transform)
    //   Group 3 (alpha): 256 symbols
    //   Group 4 (distance):  40 symbols  (LZ77 distance prefix codes)
    final List<int> greenFrequencies = List<int>.filled(280, 0);
    final List<int> redFrequencies = List<int>.filled(256, 0);
    final List<int> blueFrequencies = List<int>.filled(256, 0);
    final List<int> alphaFrequencies = List<int>.filled(256, 0);
    final List<int> distanceFrequencies = List<int>.filled(40, 0);

    int literalIndex = 0;
    int copyIndex = 0;
    for (final bool isLiteral in literalTokens) {
      if (isLiteral) {
        final int index = literalPixelIndices[literalIndex++];
        greenFrequencies[green[index]]++;
        redFrequencies[red[index]]++;
        blueFrequencies[blue[index]]++;
        alphaFrequencies[alpha[index]]++;
      } else {
        final int length = copyLengths[copyIndex];
        final int distance = copyDistances[copyIndex];
        copyIndex++;
        greenFrequencies[_lengthSymbol(length)]++;
        final int planeCode = _distanceToPlaneCode(width, distance);
        distanceFrequencies[_distancePrefixSymbol(planeCode)]++;
      }
    }

    // Build optimal Huffman code lengths.
    final List<int> greenCodeLengths = _buildHuffmanCodeLengths(greenFrequencies, 280);
    final List<int> redCodeLengths = _buildHuffmanCodeLengths(redFrequencies, 256);
    final List<int> blueCodeLengths = _buildHuffmanCodeLengths(blueFrequencies, 256);
    final List<int> alphaCodeLengths = _buildHuffmanCodeLengths(alphaFrequencies, 256);
    final List<int> distanceCodeLengths = _buildHuffmanCodeLengths(distanceFrequencies, 40);

    // Write Huffman code definitions.
    _writeHuffmanCode(bitWriter, 280, greenCodeLengths);
    _writeHuffmanCode(bitWriter, 256, redCodeLengths);
    _writeHuffmanCode(bitWriter, 256, blueCodeLengths);
    _writeHuffmanCode(bitWriter, 256, alphaCodeLengths);
    _writeHuffmanCode(bitWriter, 40, distanceCodeLengths);

    // Build canonical codes for encoding.
    final List<int> greenCodes = _canonicalCodes(Int32List.fromList(greenCodeLengths), 280);
    final List<int> redCodes = _canonicalCodes(Int32List.fromList(redCodeLengths), 256);
    final List<int> blueCodes = _canonicalCodes(Int32List.fromList(blueCodeLengths), 256);
    final List<int> alphaCodes = _canonicalCodes(Int32List.fromList(alphaCodeLengths), 256);
    final List<int> distanceCodes = _canonicalCodes(Int32List.fromList(distanceCodeLengths), 40);

    // Write token stream.
    literalIndex = 0;
    copyIndex = 0;
    for (final bool isLiteral in literalTokens) {
      if (isLiteral) {
        final int index = literalPixelIndices[literalIndex++];
        bitWriter
          ..writeBits(greenCodes[green[index]], greenCodeLengths[green[index]])
          ..writeBits(redCodes[red[index]], redCodeLengths[red[index]])
          ..writeBits(blueCodes[blue[index]], blueCodeLengths[blue[index]])
          ..writeBits(alphaCodes[alpha[index]], alphaCodeLengths[alpha[index]]);
      } else {
        final int length = copyLengths[copyIndex];
        final int distance = copyDistances[copyIndex];
        copyIndex++;

        // Write length prefix in the green channel.
        final int lengthSymbol = _lengthSymbol(length);
        bitWriter.writeBits(greenCodes[lengthSymbol], greenCodeLengths[lengthSymbol]);
        final (int extraBitCount, int extraValue) = _lengthExtra(length);
        if (extraBitCount > 0) {
          bitWriter.writeBits(extraValue, extraBitCount);
        }

        // Write distance prefix in the distance channel.
        final int planeCode = _distanceToPlaneCode(width, distance);
        final int distanceSymbol = _distancePrefixSymbol(planeCode);
        bitWriter.writeBits(distanceCodes[distanceSymbol], distanceCodeLengths[distanceSymbol]);
        final (int distanceExtraBitCount, int distanceExtraValue) = _distancePrefixExtra(planeCode);
        if (distanceExtraBitCount > 0) {
          bitWriter.writeBits(distanceExtraValue, distanceExtraBitCount);
        }
      }
    }

    bitWriter.flush();
    output.writeBytes(bitWriter.getBytes());
    return output.getBytes();
  }

  // ---------------------------------------------------------------------------
  // Transforms
  // ---------------------------------------------------------------------------

  /// Subtracts the green channel from the red and blue channels in place.
  void _applySubtractGreenTransform({
    required Uint8List red,
    required Uint8List green,
    required Uint8List blue,
    required int pixelCount,
  }) {
    for (int i = 0; i < pixelCount; i++) {
      red[i] = (red[i] - green[i]) & 0xFF;
      blue[i] = (blue[i] - green[i]) & 0xFF;
    }
  }

  /// Selects the best predictor mode for each predictor block.
  ///
  /// Tries modes 1, 2, 7, 11 and picks the one minimising |residuals|.
  List<int> _selectPredictorModes({
    required Uint8List red,
    required Uint8List green,
    required Uint8List blue,
    required Uint8List alpha,
    required int width,
    required int height,
    required int blockWidth,
    required int blockHeight,
    required int blockSize,
  }) {
    const List<int> candidates = [1, 2, 7, 11];
    final List<int> modes = List<int>.filled(blockWidth * blockHeight, 11);
    for (int blockY = 0; blockY < blockHeight; blockY++) {
      for (int blockX = 0; blockX < blockWidth; blockX++) {
        final int x0 = blockX * blockSize;
        final int y0 = blockY * blockSize;
        final int x1 = (x0 + blockSize).clamp(0, width);
        final int y1 = (y0 + blockSize).clamp(0, height);
        int bestMode = 11;
        int bestCost = 0x7fffffff;
        for (final int mode in candidates) {
          int cost = 0;
          for (int y = y0; y < y1; y++) {
            for (int x = x0; x < x1; x++) {
              final int pixelIndex = y * width + x;
              int predictedRed;
              int predictedGreen;
              int predictedBlue;
              if (y == 0 && x == 0) {
                predictedRed = 0;
                predictedGreen = 0;
                predictedBlue = 0;
              } else if (y == 0) {
                final int leftIndex = pixelIndex - 1;
                predictedRed = red[leftIndex];
                predictedGreen = green[leftIndex];
                predictedBlue = blue[leftIndex];
              } else if (x == 0) {
                final int topIndex = pixelIndex - width;
                predictedRed = red[topIndex];
                predictedGreen = green[topIndex];
                predictedBlue = blue[topIndex];
              } else {
                final int leftIndex = pixelIndex - 1;
                final int topIndex = pixelIndex - width;
                switch (mode) {
                  case 1:
                    predictedRed = red[leftIndex];
                    predictedGreen = green[leftIndex];
                    predictedBlue = blue[leftIndex];
                  case 2:
                    predictedRed = red[topIndex];
                    predictedGreen = green[topIndex];
                    predictedBlue = blue[topIndex];
                  case 7:
                    predictedRed = (red[leftIndex] + red[topIndex]) >> 1;
                    predictedGreen = (green[leftIndex] + green[topIndex]) >> 1;
                    predictedBlue = (blue[leftIndex] + blue[topIndex]) >> 1;
                  default: // 11: select
                    final int topLeftIndex = topIndex - 1;
                    final int leftScore = (red[leftIndex] - red[topLeftIndex]).abs() + (green[leftIndex] - green[topLeftIndex]).abs() + (blue[leftIndex] - blue[topLeftIndex]).abs();
                    final int topScore = (red[topIndex] - red[topLeftIndex]).abs() + (green[topIndex] - green[topLeftIndex]).abs() + (blue[topIndex] - blue[topLeftIndex]).abs();
                    if (leftScore <= topScore) {
                      predictedRed = red[topIndex];
                      predictedGreen = green[topIndex];
                      predictedBlue = blue[topIndex];
                    } else {
                      predictedRed = red[leftIndex];
                      predictedGreen = green[leftIndex];
                      predictedBlue = blue[leftIndex];
                    }
                }
              }
              final int redDifference = (red[pixelIndex] - predictedRed) & 0xFF;
              final int greenDifference = (green[pixelIndex] - predictedGreen) & 0xFF;
              final int blueDifference = (blue[pixelIndex] - predictedBlue) & 0xFF;
              // Signed magnitude: values > 127 wrap to negative residuals.
              cost += redDifference < 128 ? redDifference : 256 - redDifference;
              cost += greenDifference < 128 ? greenDifference : 256 - greenDifference;
              cost += blueDifference < 128 ? blueDifference : 256 - blueDifference;
            }
          }
          if (cost < bestCost) {
            bestCost = cost;
            bestMode = mode;
          }
        }
        modes[blockY * blockWidth + blockX] = bestMode;
      }
    }
    return modes;
  }

  /// Applies the VP8L predictor transform in place.
  ///
  /// Edge rules match the decoder: (0,0)=black, y==0=mode1, x==0=mode2.
  void _applyPredictorTransform({
    required Uint8List red,
    required Uint8List green,
    required Uint8List blue,
    required Uint8List alpha,
    required int width,
    required int height,
    required int blockWidth,
    required int blockSize,
    required List<int> modes,
  }) {
    final Uint8List originalRed = Uint8List.fromList(red);
    final Uint8List originalGreen = Uint8List.fromList(green);
    final Uint8List originalBlue = Uint8List.fromList(blue);
    final Uint8List originalAlpha = Uint8List.fromList(alpha);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int i = y * width + x;
        int predictedRed;
        int predictedGreen;
        int predictedBlue;
        int predictedAlpha;
        if (y == 0 && x == 0) {
          predictedAlpha = 255;
          predictedRed = 0;
          predictedGreen = 0;
          predictedBlue = 0;
        } else if (y == 0) {
          final int leftIndex = i - 1;
          predictedRed = originalRed[leftIndex];
          predictedGreen = originalGreen[leftIndex];
          predictedBlue = originalBlue[leftIndex];
          predictedAlpha = originalAlpha[leftIndex];
        } else if (x == 0) {
          final int topIndex = i - width;
          predictedRed = originalRed[topIndex];
          predictedGreen = originalGreen[topIndex];
          predictedBlue = originalBlue[topIndex];
          predictedAlpha = originalAlpha[topIndex];
        } else {
          final int leftIndex = i - 1;
          final int topIndex = i - width;
          final int shift = blockSize.bitLength - 1;
          final int mode = modes[(y >> shift) * blockWidth + (x >> shift)];
          switch (mode) {
            case 1: // left
              predictedRed = originalRed[leftIndex];
              predictedGreen = originalGreen[leftIndex];
              predictedBlue = originalBlue[leftIndex];
              predictedAlpha = originalAlpha[leftIndex];
            case 2: // top
              predictedRed = originalRed[topIndex];
              predictedGreen = originalGreen[topIndex];
              predictedBlue = originalBlue[topIndex];
              predictedAlpha = originalAlpha[topIndex];
            case 7: // average(left, top)
              predictedRed = (originalRed[leftIndex] + originalRed[topIndex]) >> 1;
              predictedGreen = (originalGreen[leftIndex] + originalGreen[topIndex]) >> 1;
              predictedBlue = (originalBlue[leftIndex] + originalBlue[topIndex]) >> 1;
              predictedAlpha = (originalAlpha[leftIndex] + originalAlpha[topIndex]) >> 1;
            default: // 11: select(top, left, topLeft)
              final int topLeftIndex = topIndex - 1;
              final int leftScore =
                  (originalRed[leftIndex] - originalRed[topLeftIndex]).abs() +
                  (originalGreen[leftIndex] - originalGreen[topLeftIndex]).abs() +
                  (originalBlue[leftIndex] - originalBlue[topLeftIndex]).abs() +
                  (originalAlpha[leftIndex] - originalAlpha[topLeftIndex]).abs();
              final int topScore =
                  (originalRed[topIndex] - originalRed[topLeftIndex]).abs() +
                  (originalGreen[topIndex] - originalGreen[topLeftIndex]).abs() +
                  (originalBlue[topIndex] - originalBlue[topLeftIndex]).abs() +
                  (originalAlpha[topIndex] - originalAlpha[topLeftIndex]).abs();
              if (leftScore <= topScore) {
                predictedRed = originalRed[topIndex];
                predictedGreen = originalGreen[topIndex];
                predictedBlue = originalBlue[topIndex];
                predictedAlpha = originalAlpha[topIndex];
              } else {
                predictedRed = originalRed[leftIndex];
                predictedGreen = originalGreen[leftIndex];
                predictedBlue = originalBlue[leftIndex];
                predictedAlpha = originalAlpha[leftIndex];
              }
          }
        }
        red[i] = (originalRed[i] - predictedRed) & 0xFF;
        green[i] = (originalGreen[i] - predictedGreen) & 0xFF;
        blue[i] = (originalBlue[i] - predictedBlue) & 0xFF;
        alpha[i] = (originalAlpha[i] - predictedAlpha) & 0xFF;
      }
    }
  }

  /// Writes a VP8L predictor sub-image inline.
  ///
  /// The sub-image omits the RIFF container, signature, and transform loop.
  void _writePredictorSubImage({
    required _Vp8lBitWriter bitWriter,
    required int blockWidth,
    required int blockHeight,
    required List<int> modes,
  }) {
    final int pixelCount = blockWidth * blockHeight;
    // Build green-channel frequency table for the sub-image pixels.
    final List<int> greenFrequencies = List<int>.filled(280, 0);
    for (final int mode in modes) {
      greenFrequencies[mode]++;
    }
    final List<int> greenCodeLengths = _buildHuffmanCodeLengths(greenFrequencies, 280);
    final List<int> greenCodes = _canonicalCodes(Int32List.fromList(greenCodeLengths), 280);

    // Sub-image format (decoded with isLevel0=false, allowRecursion=false):
    // no color cache, then 5 Huffman groups, then pixel data.
    bitWriter.writeBits(0, 1); // no color cache
    // Green (280): normal Huffman for the mode values.
    _writeHuffmanCode(bitWriter, 280, greenCodeLengths);
    // Red/Blue (256): all 0 → simple, 1-bit symbol = 0.
    // Alpha (256): all 255 → simple, 8-bit symbol = 255.
    // Dist (40): unused → simple, 1-bit symbol = 0.
    bitWriter
      ..writeBits(1, 1) // red: is_simple=1
      ..writeBits(0, 1) // 1 symbol
      ..writeBits(0, 1) // 1-bit symbol
      ..writeBits(0, 1) // symbol = 0
      ..writeBits(1, 1) // blue: is_simple=1
      ..writeBits(0, 1)
      ..writeBits(0, 1)
      ..writeBits(0, 1)
      ..writeBits(1, 1) // alpha: is_simple=1
      ..writeBits(0, 1)
      ..writeBits(1, 1) // 8-bit symbol
      ..writeBits(255, 8)
      ..writeBits(1, 1) // distance: is_simple=1
      ..writeBits(0, 1)
      ..writeBits(0, 1)
      ..writeBits(0, 1);
    // Pixel data: blockW*blockH pixels with G=modes[i], R=0, B=0, A=255.
    // Red/blue/alpha each have a 1-symbol code → 1 bit each.
    for (int index = 0; index < pixelCount; index++) {
      final int mode = modes[index];
      bitWriter.writeBits(greenCodes[mode], greenCodeLengths[mode]);
    }
  }

  // ---------------------------------------------------------------------------
  // VP8L length and distance encoding helpers
  // ---------------------------------------------------------------------------

  /// VP8L green-channel symbol for a back-reference of [length].
  int _lengthSymbol(int length) {
    assert(length >= 1 && length <= 4096, 'length must be between 1 and 4096');
    if (length <= 4) {
      return 255 + length; // symbols 256..259
    }
    final int mostSignificantBit = _floorLog2(length - 1);
    final int half = (length - 1) >> (mostSignificantBit - 1) & 1;
    return 256 + 2 * mostSignificantBit + half; // symbols 260..279
  }

  /// Extra bits for VP8L length prefix code for back-reference [length].
  (int extraBits, int extraValue) _lengthExtra(int length) {
    if (length <= 4) {
      return (0, 0);
    }
    final int mostSignificantBit = _floorLog2(length - 1);
    final int half = (length - 1) >> (mostSignificantBit - 1) & 1;
    final int extraBitCount = mostSignificantBit - 1;
    final int base = (2 + half) << extraBitCount;
    return (extraBitCount, (length - 1) - base);
  }

  /// Converts a pixel distance to the corresponding VP8L plane code.
  int _distanceToPlaneCode(int width, int distance) {
    final int verticalOffset = distance ~/ width;
    final int horizontalOffset = distance - verticalOffset * width;
    if (horizontalOffset <= 8 && verticalOffset < 8) {
      return _distancePlaneLookup[verticalOffset * 16 + 8 - horizontalOffset] + 1;
    } else if (horizontalOffset > width - 8 && verticalOffset < 7) {
      return _distancePlaneLookup[(verticalOffset + 1) * 16 + 8 + width - horizontalOffset] + 1;
    }
    return distance + 120;
  }

  /// VP8L prefix code (distance alphabet symbol) for a plane code [v].
  int _distancePrefixSymbol(int v) {
    final int adjustedValue = v - 1;
    if (adjustedValue < 4) {
      return adjustedValue;
    }
    final int mostSignificantBit = _floorLog2(adjustedValue);
    final int half = adjustedValue >> (mostSignificantBit - 1) & 1;
    return 2 * mostSignificantBit + half;
  }

  /// Extra bits for the VP8L distance prefix code for plane code [v].
  (int extraBits, int extraValue) _distancePrefixExtra(int v) {
    final int adjustedValue = v - 1;
    if (adjustedValue < 4) {
      return (0, 0);
    }
    final int mostSignificantBit = _floorLog2(adjustedValue);
    final int half = adjustedValue >> (mostSignificantBit - 1) & 1;
    final int extraBitCount = mostSignificantBit - 1;
    final int base = (2 + half) << extraBitCount;
    return (extraBitCount, adjustedValue - base);
  }

  /// Returns the integer base-two logarithm of the positive value [v].
  int _floorLog2(int v) {
    int currentValue = v;
    int log = 0;
    while (currentValue > 1) {
      currentValue >>= 1;
      log++;
    }
    return log;
  }

  // ---------------------------------------------------------------------------
  // Huffman coding
  // ---------------------------------------------------------------------------

  /// Builds optimal Huffman code lengths for [alphabetSize] symbols.
  ///
  /// their [frequencies]uencies. Returns an array where entry i is the code length
  /// for symbol i (0 = unused). All lengths are ≤ [maxBits] (15 for VP8L).
  List<int> _buildHuffmanCodeLengths(
    List<int> frequencies,
    int alphabetSize, {
    int maxBits = 15,
  }) {
    final List<int> codeLengths = List<int>.filled(alphabetSize, 0);

    final List<int> symbols = <int>[];
    for (int k = 0; k < alphabetSize; k++) {
      if (frequencies[k] > 0) {
        symbols.add(k);
      }
    }

    if (symbols.isEmpty) {
      codeLengths[0] = 1;
      return codeLengths;
    }
    if (symbols.length == 1) {
      codeLengths[symbols[0]] = 1;
      return codeLengths;
    }

    final int maxNodes = 2 * symbols.length;
    final List<int> nodeFrequencies = List<int>.filled(maxNodes, 0);
    final List<int> leftChildren = List<int>.filled(maxNodes, -1);
    final List<int> rightChildren = List<int>.filled(maxNodes, -1);

    for (int countMin = 1; ; countMin *= 2) {
      for (int k = 0; k < symbols.length; k++) {
        nodeFrequencies[k] = frequencies[symbols[k]];
        if (nodeFrequencies[k] < countMin) {
          nodeFrequencies[k] = countMin;
        }
      }
      int nextNode = symbols.length;

      final List<int> priorityQueue = List<int>.generate(symbols.length, (k) => k)..sort((x, y) => nodeFrequencies[x].compareTo(nodeFrequencies[y]));

      while (priorityQueue.length > 1) {
        final int x = priorityQueue.removeAt(0);
        final int y = priorityQueue.removeAt(0);
        final int id = nextNode++;
        nodeFrequencies[id] = nodeFrequencies[x] + nodeFrequencies[y];
        leftChildren[id] = x;
        rightChildren[id] = y;
        int pos = 0;
        while (pos < priorityQueue.length && nodeFrequencies[priorityQueue[pos]] <= nodeFrequencies[id]) {
          pos++;
        }
        priorityQueue.insert(pos, id);
      }

      // Assign code lengths via iterative DFS.
      final List<int> stackNodes = <int>[priorityQueue[0]];
      final List<int> stackDepths = <int>[0];
      int currentMaxBits = 0;

      while (stackNodes.isNotEmpty) {
        final int nodeId = stackNodes.removeLast();
        final int depth = stackDepths.removeLast();
        if (leftChildren[nodeId] == -1) {
          codeLengths[symbols[nodeId]] = depth;
          if (depth > currentMaxBits) {
            currentMaxBits = depth;
          }
        } else {
          stackNodes
            ..add(leftChildren[nodeId])
            ..add(rightChildren[nodeId]);
          stackDepths
            ..add(depth + 1)
            ..add(depth + 1);
        }
      }

      if (currentMaxBits <= maxBits) {
        break;
      }
    }

    return codeLengths;
  }

  /// Writes a Huffman code definition in VP8L format.
  void _writeHuffmanCode(
    _Vp8lBitWriter bitWriter,
    int alphabetSize,
    List<int> codeLengths,
  ) {
    final List<int> used = <int>[];
    for (int k = 0; k < alphabetSize; k++) {
      if (codeLengths[k] > 0) {
        used.add(k);
      }
    }

    if (used.length <= 2 && (used.isEmpty || used.last <= 255)) {
      // Simple code format.
      bitWriter.writeBits(1, 1); // is_simple_code = 1
      if (used.isEmpty) {
        bitWriter
          ..writeBits(0, 1) // 1 symbol
          ..writeBits(0, 1) // 1-bit symbol
          ..writeBits(0, 1); // symbol = 0
        return;
      }
      bitWriter.writeBits(used.length - 1, 1); // num_symbols - 1
      final int firstSymbol = used[0];
      if (firstSymbol <= 1) {
        bitWriter
          ..writeBits(0, 1) // first_symbol_len_code = 0 (1-bit symbol)
          ..writeBits(firstSymbol, 1); // symbol
      } else {
        bitWriter
          ..writeBits(1, 1) // first_symbol_len_code = 1 (8-bit symbol)
          ..writeBits(firstSymbol, 8);
      }
      if (used.length == 2) {
        bitWriter.writeBits(used[1], 8);
      } else if (used.length == 1) {
        // 1-symbol simple codes take 0 bits in the bitstream.
        codeLengths[firstSymbol] = 0;
      }
      return;
    }

    // Normal code format.
    final List<_CodeLengthSymbol> runLengthSymbols = _buildRunLengthSequence(codeLengths, alphabetSize);

    final List<int> codeLengthFrequencies = List<int>.filled(19, 0);
    for (final _CodeLengthSymbol symbol in runLengthSymbols) {
      codeLengthFrequencies[symbol.symbol]++;
    }

    final List<int> codeLengthCodeLengths = _buildHuffmanCodeLengths(codeLengthFrequencies, 19, maxBits: 7);
    final List<int> codeLengthCodes = _canonicalCodes(Int32List.fromList(codeLengthCodeLengths), 19);

    const List<int> codeLengthOrder = [
      17,
      18,
      0,
      1,
      2,
      3,
      4,
      5,
      16,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
    ];

    int codeLengthCount = 4;
    for (int k = 18; k >= 4; k--) {
      if (codeLengthCodeLengths[codeLengthOrder[k]] != 0) {
        codeLengthCount = k + 1;
        break;
      }
    }

    bitWriter
      ..writeBits(0, 1) // is_simple_code = 0
      ..writeBits(codeLengthCount - 4, 4); // num_code_lengths - 4

    for (int k = 0; k < codeLengthCount; k++) {
      bitWriter.writeBits(codeLengthCodeLengths[codeLengthOrder[k]], 3);
    }

    bitWriter.writeBits(0, 1); // use_length = 0

    for (final _CodeLengthSymbol symbol in runLengthSymbols) {
      bitWriter.writeBits(codeLengthCodes[symbol.symbol], codeLengthCodeLengths[symbol.symbol]);
      if (symbol.extraBits > 0) {
        bitWriter.writeBits(symbol.extraValue, symbol.extraBits);
      }
    }
  }

  /// Builds the run-length sequence for a code-length array.
  ///
  /// 0-15 (literal lengths), 16 (repeat prev 3-6×),
  /// 17 (repeat zero 3-10×), 18 (repeat zero 11-138×).
  List<_CodeLengthSymbol> _buildRunLengthSequence(List<int> codeLengths, int alphabetSize) {
    final List<_CodeLengthSymbol> result = <_CodeLengthSymbol>[];
    int i = 0;
    while (i < alphabetSize) {
      final int currentCodeLength = codeLengths[i];
      if (currentCodeLength == 0) {
        int count = 0;
        while (i + count < alphabetSize && codeLengths[i + count] == 0) {
          count++;
        }
        int remaining = count;
        while (remaining > 0) {
          if (remaining >= 11) {
            final int n = remaining.clamp(11, 138);
            result.add(_CodeLengthSymbol(symbol: 18, extraBits: 7, extraValue: n - 11));
            remaining -= n;
          } else if (remaining >= 3) {
            final int n = remaining.clamp(3, 10);
            result.add(_CodeLengthSymbol(symbol: 17, extraBits: 3, extraValue: n - 3));
            remaining -= n;
          } else {
            result.add(const _CodeLengthSymbol(symbol: 0, extraBits: 0, extraValue: 0));
            remaining--;
          }
        }
        i += count;
      } else {
        result.add(_CodeLengthSymbol(symbol: currentCodeLength, extraBits: 0, extraValue: 0));
        i++;
        while (i < alphabetSize && codeLengths[i] == currentCodeLength) {
          int count = 0;
          while (i + count < alphabetSize && codeLengths[i + count] == currentCodeLength && count < 6) {
            count++;
          }
          if (count >= 3) {
            result.add(_CodeLengthSymbol(symbol: 16, extraBits: 2, extraValue: count - 3));
            i += count;
          } else {
            for (int k = 0; k < count; k++) {
              result.add(_CodeLengthSymbol(symbol: currentCodeLength, extraBits: 0, extraValue: 0));
            }
            i += count;
          }
        }
      }
    }
    return result;
  }

  /// Computes canonical Huffman codes in least-significant-bit order.
  List<int> _canonicalCodes(Int32List codeLengths, int numSymbols) {
    final List<int> codes = List<int>.filled(numSymbols, 0);
    int maxLen = 0;
    for (int k = 0; k < numSymbols; k++) {
      if (codeLengths[k] > maxLen) {
        maxLen = codeLengths[k];
      }
    }
    if (maxLen == 0) {
      return codes;
    }

    final List<int> bitLengthCounts = List<int>.filled(maxLen + 1, 0);
    for (int k = 0; k < numSymbols; k++) {
      if (codeLengths[k] > 0) {
        bitLengthCounts[codeLengths[k]]++;
      }
    }
    bitLengthCounts[0] = 0;

    final List<int> nextCode = List<int>.filled(maxLen + 1, 0);
    int code = 0;
    for (int bits = 1; bits <= maxLen; bits++) {
      code = (code + bitLengthCounts[bits - 1]) << 1;
      nextCode[bits] = code;
    }

    for (int k = 0; k < numSymbols; k++) {
      final int len = codeLengths[k];
      if (len > 0) {
        codes[k] = _reverseBits(nextCode[len], len);
        nextCode[len]++;
      }
    }

    return codes;
  }

  /// Reverses the lowest [numBits] of [value].
  int _reverseBits(int value, int numBits) {
    int currentValue = value;
    int result = 0;
    for (int k = 0; k < numBits; k++) {
      result = (result << 1) | (currentValue & 1);
      currentValue >>= 1;
    }
    return result;
  }

  /// Converts the ASCII RIFF tag [s] to bytes.
  Uint8List _encodeRiffTag({required String value}) {
    final Uint8List bytes = Uint8List(value.length);
    for (int index = 0; index < value.length; index++) {
      bytes[index] = value.codeUnitAt(index);
    }
    return bytes;
  }
}

/// A code-length symbol with optional extra bits.
final class _CodeLengthSymbol {
  /// Code-length alphabet symbol.
  final int symbol;

  /// Number of extra bits following [symbol].
  final int extraBits;

  /// Value stored in the extra bits.
  final int extraValue;

  /// Creates a code-length symbol and its optional extra-bit payload.
  const _CodeLengthSymbol({
    required this.symbol,
    required this.extraBits,
    required this.extraValue,
  });
}

/// Bit writer that packs bits LSB-first into bytes.
final class _Vp8lBitWriter {
  /// Completed output bytes.
  final List<int> _bytes = <int>[];

  /// Byte currently being assembled.
  int _currentByte = 0;

  /// Number of low-order bits already occupied in [_currentByte].
  int _usedBits = 0;

  /// Creates an empty bit writer.
  _Vp8lBitWriter();

  /// Writes the lowest [numBits] of [value] in least-significant-bit order.
  void writeBits(int value, int numBits) {
    int currentValue = value;
    int currentNumBits = numBits;
    while (currentNumBits > 0) {
      final int available = 8 - _usedBits;
      final int bitsToWrite = currentNumBits < available ? currentNumBits : available;
      final int mask = (1 << bitsToWrite) - 1;
      _currentByte |= (currentValue & mask) << _usedBits;
      currentValue >>= bitsToWrite;
      currentNumBits -= bitsToWrite;
      _usedBits += bitsToWrite;
      if (_usedBits == 8) {
        _bytes.add(_currentByte);
        _currentByte = 0;
        _usedBits = 0;
      }
    }
  }

  /// Pads and emits the partially filled byte, when present.
  void flush() {
    if (_usedBits > 0) {
      _bytes.add(_currentByte);
      _currentByte = 0;
      _usedBits = 0;
    }
  }

  /// Returns a copy of all emitted bytes.
  Uint8List getBytes() => Uint8List.fromList(_bytes);
}
