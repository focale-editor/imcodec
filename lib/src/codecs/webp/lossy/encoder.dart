part of '../../webp.dart';

/// Visits one residual block and returns whether it contains a nonzero value.
typedef _Vp8ResidualVisitor = int Function(
  _Vp8LossyMacroblock macroblock,
  int coefficientOffset,
  int firstCoefficient,
  int type,
  int context,
);

/// Encodes one still image as an intra-only lossy VP8 key frame.
final class _Vp8LossyEncoder {
  /// Requested quality after public API clamping.
  final int quality;

  /// Candidate-search level used by mode selection and quantization.
  final WebPEffort effort;

  /// Original image width.
  late int _width;

  /// Original image height.
  late int _height;

  /// Number of sixteen-pixel macroblocks in one row.
  late int _macroblockWidth;

  /// Number of sixteen-pixel macroblocks in one column.
  late int _macroblockHeight;

  /// Source and reconstructed sample planes.
  late _Vp8LossyPlanes _planes;

  /// Quantization configuration derived from [quality].
  late _Vp8EncoderQuantizers _quantizers;

  /// Completed macroblocks in raster order.
  late List<_Vp8LossyMacroblock> _macroblocks;

  /// Whether the frame uses explicit macroblock skip flags.
  late bool _usesSkipProbability;

  /// Probability that a macroblock is not skipped.
  late int _skipProbability;

  /// Creates a lossy encoder with validated public options.
  _Vp8LossyEncoder({
    required this.quality,
    required this.effort,
  });

  /// Encodes [image] into a RIFF/WebP container.
  Uint8List encode(Image image) {
    _checkInput(image);
    _width = image.width;
    _height = image.height;
    _macroblockWidth = (_width + 15) >> 4;
    _macroblockHeight = (_height + 15) >> 4;
    _quantizers = _Vp8EncoderQuantizers(
      index: _qualityToQuantizer(quality),
    );
    _planes = _convertToYuv(image);
    _macroblocks = _analyzeMacroblocks();

    final int skipCount = _macroblocks.where((macroblock) => macroblock.skip).length;
    _usesSkipProbability = skipCount > 0;
    final int macroblockCount = _macroblocks.length;
    _skipProbability = macroblockCount == 0 ? 255 : ((255 * (macroblockCount - skipCount) + macroblockCount ~/ 2) ~/ macroblockCount).clamp(1, 255);

    final Int32List statistics = Int32List(_vp8ProbabilityTotal * 2);
    _visitResiduals(
      honorSkip: _usesSkipProbability,
      visitor: (macroblock, coefficientOffset, firstCoefficient, type, context) => _walkCoefficients(
        coefficients: macroblock.coefficients,
        coefficientOffset: coefficientOffset,
        firstCoefficient: firstCoefficient,
        type: type,
        context: context,
        probabilities: _Vp8EncoderTables.defaultProbabilities,
        statistics: statistics,
      ).$1,
    );
    final Uint8List probabilities = _selectProbabilities(statistics);
    final Uint8List partitionZero = _writePartitionZero(probabilities);
    final Uint8List tokenPartition = _writeTokenPartition(probabilities);
    final Uint8List vp8 = _assembleVp8(
      partitionZero: partitionZero,
      tokenPartition: tokenPartition,
    );
    return _wrapContainer(vp8);
  }

  /// Rejects dimensions that the fourteen-bit VP8 key-frame header cannot hold.
  void _checkInput(Image image) {
    if (image.width > 16383 || image.height > 16383) {
      throw const ImageCodecException(
        'Lossy WebP dimensions may not exceed 16383 pixels',
      );
    }
  }

  /// Maps a user-facing quality to VP8's inverse quantizer scale.
  static int _qualityToQuantizer(int quality) {
    final double normalized = quality / 100;
    final double linearCompression = normalized < 0.75 ? normalized * (2 / 3) : 2 * normalized - 1;
    final double compression = math.pow(linearCompression, 1 / 3).toDouble();
    return (127 * (1 - compression)).floor().clamp(0, 127);
  }

  /// Converts straight RGBA pixels to padded limited-range YUV 4:2:0 planes.
  _Vp8LossyPlanes _convertToYuv(Image image) {
    final int lumaStride = _macroblockWidth * 16;
    final int lumaHeight = _macroblockHeight * 16;
    final int chromaStride = _macroblockWidth * 8;
    final int chromaHeight = _macroblockHeight * 8;
    final Uint8List luma = Uint8List(lumaStride * lumaHeight);
    final Uint8List blueDifference = Uint8List(chromaStride * chromaHeight);
    final Uint8List redDifference = Uint8List(chromaStride * chromaHeight);
    final Uint8List source = image.bytes;

    for (int y = 0; y < chromaHeight; ++y) {
      final int sourceY0 = math.min(2 * y, _height - 1);
      final int sourceY1 = math.min(sourceY0 + 1, _height - 1);
      final int lumaRow0 = 2 * y * lumaStride;
      final int lumaRow1 = lumaRow0 + lumaStride;
      for (int x = 0; x < chromaStride; ++x) {
        final int sourceX0 = math.min(2 * x, _width - 1);
        final int sourceX1 = math.min(sourceX0 + 1, _width - 1);
        final int sourceOffset00 = (sourceY0 * _width + sourceX0) * 4;
        final int sourceOffset01 = (sourceY0 * _width + sourceX1) * 4;
        final int sourceOffset10 = (sourceY1 * _width + sourceX0) * 4;
        final int sourceOffset11 = (sourceY1 * _width + sourceX1) * 4;
        final int red00 = source[sourceOffset00];
        final int green00 = source[sourceOffset00 + 1];
        final int blue00 = source[sourceOffset00 + 2];
        final int red01 = source[sourceOffset01];
        final int green01 = source[sourceOffset01 + 1];
        final int blue01 = source[sourceOffset01 + 2];
        final int red10 = source[sourceOffset10];
        final int green10 = source[sourceOffset10 + 1];
        final int blue10 = source[sourceOffset10 + 2];
        final int red11 = source[sourceOffset11];
        final int green11 = source[sourceOffset11 + 1];
        final int blue11 = source[sourceOffset11 + 2];
        final int lumaX = 2 * x;
        luma[lumaRow0 + lumaX] = _rgbToLuma(red00, green00, blue00);
        luma[lumaRow0 + lumaX + 1] = _rgbToLuma(red01, green01, blue01);
        luma[lumaRow1 + lumaX] = _rgbToLuma(red10, green10, blue10);
        luma[lumaRow1 + lumaX + 1] = _rgbToLuma(red11, green11, blue11);
        final int blueSum =
            _rgbToBlueDifference(red00, green00, blue00) + _rgbToBlueDifference(red01, green01, blue01) + _rgbToBlueDifference(red10, green10, blue10) + _rgbToBlueDifference(red11, green11, blue11);
        final int redSum =
            _rgbToRedDifference(red00, green00, blue00) + _rgbToRedDifference(red01, green01, blue01) + _rgbToRedDifference(red10, green10, blue10) + _rgbToRedDifference(red11, green11, blue11);
        final int destination = y * chromaStride + x;
        blueDifference[destination] = (blueSum + 2) >> 2;
        redDifference[destination] = (redSum + 2) >> 2;
      }
    }

    final int sourcePixelCount = _width * _height;
    Uint8List? alpha;
    for (int pixel = 0; pixel < sourcePixelCount; ++pixel) {
      if (source[pixel * 4 + 3] != 255) {
        alpha = Uint8List(sourcePixelCount)..fillRange(0, pixel, 255);
        for (int alphaPixel = pixel; alphaPixel < sourcePixelCount; ++alphaPixel) {
          alpha[alphaPixel] = source[alphaPixel * 4 + 3];
        }
        break;
      }
    }

    return _Vp8LossyPlanes(
      luma: luma,
      blueDifference: blueDifference,
      redDifference: redDifference,
      reconstructedLuma: Uint8List(luma.length),
      reconstructedBlueDifference: Uint8List(blueDifference.length),
      reconstructedRedDifference: Uint8List(redDifference.length),
      alpha: alpha,
      lumaStride: lumaStride,
      chromaStride: chromaStride,
    );
  }

  /// Converts one RGB pixel to limited-range luma.
  static int _rgbToLuma(int red, int green, int blue) => (((66 * red + 129 * green + 25 * blue + 128) >> 8) + 16).clamp(0, 255);

  /// Converts one RGB pixel to limited-range blue difference.
  static int _rgbToBlueDifference(int red, int green, int blue) => (((-38 * red - 74 * green + 112 * blue + 128) >> 8) + 128).clamp(0, 255);

  /// Converts one RGB pixel to limited-range red difference.
  static int _rgbToRedDifference(int red, int green, int blue) => (((112 * red - 94 * green - 18 * blue + 128) >> 8) + 128).clamp(0, 255);

  /// Chooses prediction modes and reconstructs every macroblock.
  List<_Vp8LossyMacroblock> _analyzeMacroblocks() {
    final List<_Vp8LossyMacroblock> macroblocks = <_Vp8LossyMacroblock>[];
    final Uint8List topModes = Uint8List(_macroblockWidth * 4);
    final Uint8List leftModes = Uint8List(4);
    for (int macroblockY = 0; macroblockY < _macroblockHeight; ++macroblockY) {
      leftModes.fillRange(0, leftModes.length, 0);
      for (int macroblockX = 0; macroblockX < _macroblockWidth; ++macroblockX) {
        final _Vp8LumaCandidate luma = _chooseLuma(
          macroblockX: macroblockX,
          macroblockY: macroblockY,
          topModes: topModes,
          leftModes: leftModes,
        );
        final _Vp8ChromaCandidate chroma = _chooseChroma(
          macroblockX: macroblockX,
          macroblockY: macroblockY,
        );
        final Int16List coefficients =
            Int16List(
                _vp8MacroblockCoefficientCount,
              )
              ..setRange(0, _vp8ChromaCoefficientOffset, luma.coefficients)
              ..setRange(
                _vp8ChromaCoefficientOffset,
                _vp8SecondaryLumaCoefficientOffset,
                chroma.coefficients,
              )
              ..setRange(
                _vp8SecondaryLumaCoefficientOffset,
                _vp8MacroblockCoefficientCount,
                luma.coefficients,
                _vp8SecondaryLumaCoefficientOffset,
              );
        bool skip = true;
        for (final int coefficient in coefficients) {
          if (coefficient != 0) {
            skip = false;
            break;
          }
        }
        macroblocks.add(
          _Vp8LossyMacroblock(
            isIntra4x4: luma.isIntra4x4,
            lumaModes: luma.modes,
            chromaMode: chroma.mode,
            coefficients: coefficients,
            skip: skip,
          ),
        );

        _copyBlock(
          source: luma.reconstruction,
          sourceStride: 16,
          destination: _planes.reconstructedLuma,
          destinationStride: _planes.lumaStride,
          destinationX: macroblockX * 16,
          destinationY: macroblockY * 16,
          size: 16,
        );
        _copyBlock(
          source: chroma.blueDifference,
          sourceStride: 8,
          destination: _planes.reconstructedBlueDifference,
          destinationStride: _planes.chromaStride,
          destinationX: macroblockX * 8,
          destinationY: macroblockY * 8,
          size: 8,
        );
        _copyBlock(
          source: chroma.redDifference,
          sourceStride: 8,
          destination: _planes.reconstructedRedDifference,
          destinationStride: _planes.chromaStride,
          destinationX: macroblockX * 8,
          destinationY: macroblockY * 8,
          size: 8,
        );

        final int topModeOffset = macroblockX * 4;
        if (luma.isIntra4x4) {
          for (int row = 0; row < 4; ++row) {
            leftModes[row] = luma.modes[row * 4 + 3];
          }
          topModes.setRange(
            topModeOffset,
            topModeOffset + 4,
            luma.modes,
            12,
          );
        } else {
          topModes.fillRange(
            topModeOffset,
            topModeOffset + 4,
            luma.modes[0],
          );
          leftModes.fillRange(0, leftModes.length, luma.modes[0]);
        }
      }
    }
    return macroblocks;
  }

  /// Chooses between macroblock and four-by-four luma predictions.
  _Vp8LumaCandidate _chooseLuma({
    required int macroblockX,
    required int macroblockY,
    required Uint8List topModes,
    required Uint8List leftModes,
  }) {
    final _Vp8LumaCandidate bestIntra16;
    if (!effort.weighsRateAgainstDistortion) {
      int bestMode = 0;
      int bestPredictionError = 1 << 62;
      final Uint8List predictionScratch = Uint8List(16 * 16);
      for (int mode = 0; mode < 4; ++mode) {
        final Uint8List prediction = _predictBlock(
          reconstructed: _planes.reconstructedLuma,
          stride: _planes.lumaStride,
          x: macroblockX * 16,
          y: macroblockY * 16,
          size: 16,
          mode: mode,
          output: predictionScratch,
        );
        final int error = _blockError(
          source: _planes.luma,
          sourceStride: _planes.lumaStride,
          sourceOffset: macroblockY * 16 * _planes.lumaStride + macroblockX * 16,
          candidate: prediction,
          candidateStride: 16,
          size: 16,
        );
        if (error < bestPredictionError) {
          bestPredictionError = error;
          bestMode = mode;
        }
      }
      bestIntra16 = _evaluateIntra16(
        macroblockX: macroblockX,
        macroblockY: macroblockY,
        mode: bestMode,
      );
    } else {
      _Vp8LumaCandidate selected = _evaluateIntra16(
        macroblockX: macroblockX,
        macroblockY: macroblockY,
        mode: 0,
      );
      for (int mode = 1; mode < 4; ++mode) {
        final _Vp8LumaCandidate candidate = _evaluateIntra16(
          macroblockX: macroblockX,
          macroblockY: macroblockY,
          mode: mode,
        );
        if (candidate.score < selected.score) {
          selected = candidate;
        }
      }
      bestIntra16 = selected;
    }

    if (!effort.triesIntra4x4) {
      return bestIntra16;
    }
    final _Vp8LumaCandidate intra4 = _evaluateIntra4(
      macroblockX: macroblockX,
      macroblockY: macroblockY,
      topModes: topModes,
      leftModes: leftModes,
    );
    return intra4.score < bestIntra16.score ? intra4 : bestIntra16;
  }

  /// Transforms, quantizes and reconstructs one sixteen-by-sixteen candidate.
  _Vp8LumaCandidate _evaluateIntra16({
    required int macroblockX,
    required int macroblockY,
    required int mode,
  }) {
    final Uint8List prediction = _predictBlock(
      reconstructed: _planes.reconstructedLuma,
      stride: _planes.lumaStride,
      x: macroblockX * 16,
      y: macroblockY * 16,
      size: 16,
      mode: mode,
    );
    final Uint8List reconstruction = Uint8List.fromList(prediction);
    final Int16List levels = Int16List(_vp8MacroblockCoefficientCount);
    final Int32List directCurrent = Int32List(16);
    final Int32List transformedScratch = Int32List(16);
    final Int32List dequantizedBlocks = Int32List(16 * 16);
    final Int32List secondaryDequantized = Int32List(16);
    final Int32List inverseScratch = Int32List(16);
    final int sourceOffset = macroblockY * 16 * _planes.lumaStride + macroblockX * 16;
    for (int blockY = 0; blockY < 4; ++blockY) {
      for (int blockX = 0; blockX < 4; ++blockX) {
        final int block = blockY * 4 + blockX;
        final Int32List coefficients = _Vp8EncoderTransform.forward(
          _planes.luma,
          sourceOffset: sourceOffset + blockY * 4 * _planes.lumaStride + blockX * 4,
          sourceStride: _planes.lumaStride,
          prediction: prediction,
          predictionOffset: blockY * 4 * 16 + blockX * 4,
          predictionStride: 16,
          output: transformedScratch,
        );
        directCurrent[block] = coefficients[0];
        _quantize(
          transformed: coefficients,
          matrix: _quantizers.luma,
          levels: levels,
          levelOffset: block * 16,
          firstCoefficient: 1,
          dequantized: dequantizedBlocks,
          dequantizedOffset: block * 16,
        );
      }
    }

    final Int32List secondary = _Vp8EncoderTransform.forwardWalshHadamard(
      directCurrent,
    );
    final Int32List dequantizedSecondary = _quantize(
      transformed: secondary,
      matrix: _quantizers.secondaryLuma,
      levels: levels,
      levelOffset: _vp8SecondaryLumaCoefficientOffset,
      firstCoefficient: 0,
      dequantized: secondaryDequantized,
    );
    final Int32List reconstructedDirectCurrent = _Vp8EncoderTransform.inverseWalshHadamard(dequantizedSecondary);
    for (int blockY = 0; blockY < 4; ++blockY) {
      for (int blockX = 0; blockX < 4; ++blockX) {
        final int block = blockY * 4 + blockX;
        final int coefficientOffset = block * 16;
        dequantizedBlocks[coefficientOffset] = reconstructedDirectCurrent[block];
        _Vp8EncoderTransform.inverse(
          dequantizedBlocks,
          reconstruction,
          destinationOffset: blockY * 4 * 16 + blockX * 4,
          destinationStride: 16,
          coefficientOffset: coefficientOffset,
          scratch: inverseScratch,
        );
      }
    }

    int rate =
        _intra16ModeCost(mode) +
        _Vp8EncoderTables.oneCost(145) +
        _coefficientCost(
          levels,
          offset: _vp8SecondaryLumaCoefficientOffset,
          firstCoefficient: 0,
          type: 1,
        );
    for (int block = 0; block < 16; ++block) {
      rate += _coefficientCost(
        levels,
        offset: block * 16,
        firstCoefficient: 1,
        type: 0,
      );
    }
    final int distortion = _blockError(
      source: _planes.luma,
      sourceStride: _planes.lumaStride,
      sourceOffset: sourceOffset,
      candidate: reconstruction,
      candidateStride: 16,
      size: 16,
    );
    return _Vp8LumaCandidate(
      isIntra4x4: false,
      modes: Uint8List(16)..[0] = mode,
      coefficients: levels,
      reconstruction: reconstruction,
      score: distortion * _vp8BitCostUnit + _quantizers.lambda * rate,
    );
  }

  /// Selects and reconstructs sixteen four-by-four luma predictions.
  _Vp8LumaCandidate _evaluateIntra4({
    required int macroblockX,
    required int macroblockY,
    required Uint8List topModes,
    required Uint8List leftModes,
  }) {
    final Uint8List reconstruction = Uint8List(16 * 16);
    final Int16List levels = Int16List(_vp8MacroblockCoefficientCount);
    final Uint8List modes = Uint8List(16);
    final Uint8List candidateTopModes = Uint8List.fromList(
      Uint8List.sublistView(
        topModes,
        macroblockX * 4,
        macroblockX * 4 + 4,
      ),
    );
    final Uint8List candidateLeftModes = Uint8List.fromList(leftModes);
    final Int32List transformedScratch = Int32List(16);
    final Int32List dequantizedScratch = Int32List(16);
    final Int32List inverseScratch = Int32List(16);
    final Int16List candidateLevels = Int16List(16);
    final Uint8List prediction = Uint8List(16);
    final Uint8List top = Uint8List(4);
    final Uint8List left = Uint8List(4);
    int score = _quantizers.lambda * _Vp8EncoderTables.zeroCost(145);
    for (int blockY = 0; blockY < 4; ++blockY) {
      for (int blockX = 0; blockX < 4; ++blockX) {
        final int block = blockY * 4 + blockX;
        final Uint8List bestReconstruction = Uint8List(16);
        final Int16List bestLevels = Int16List(16);
        int bestMode = 0;
        int bestScore = 1 << 62;
        final (int topLeft, int topRight) = _readLuma4Boundary(
          macroblockX: macroblockX,
          macroblockY: macroblockY,
          blockX: blockX,
          blockY: blockY,
          macroblockReconstruction: reconstruction,
          top: top,
          left: left,
        );
        for (int mode = 0; mode < 4; ++mode) {
          _predictLuma4(
            top: top,
            left: left,
            topLeft: topLeft,
            topRight: topRight,
            mode: mode,
            prediction: prediction,
          );
          final Int32List transformed = _Vp8EncoderTransform.forward(
            _planes.luma,
            sourceOffset: (macroblockY * 16 + blockY * 4) * _planes.lumaStride + macroblockX * 16 + blockX * 4,
            sourceStride: _planes.lumaStride,
            prediction: prediction,
            predictionOffset: 0,
            predictionStride: 4,
            output: transformedScratch,
          );
          final Int32List dequantized = _quantize(
            transformed: transformed,
            matrix: _quantizers.luma,
            levels: candidateLevels,
            levelOffset: 0,
            firstCoefficient: 0,
            dequantized: dequantizedScratch,
          );
          _Vp8EncoderTransform.inverse(
            dequantized,
            prediction,
            destinationOffset: 0,
            destinationStride: 4,
            scratch: inverseScratch,
          );
          final int distortion = _blockError(
            source: _planes.luma,
            sourceStride: _planes.lumaStride,
            sourceOffset: (macroblockY * 16 + blockY * 4) * _planes.lumaStride + macroblockX * 16 + blockX * 4,
            candidate: prediction,
            candidateStride: 4,
            size: 4,
          );
          final int rate =
              _intra4ModeCost(
                topMode: candidateTopModes[blockX],
                leftMode: candidateLeftModes[blockY],
                mode: mode,
              ) +
              _coefficientCost(
                candidateLevels,
                offset: 0,
                firstCoefficient: 0,
                type: 3,
              );
          final int candidateScore = distortion * _vp8BitCostUnit + _quantizers.lambda * rate;
          if (candidateScore < bestScore) {
            bestScore = candidateScore;
            bestMode = mode;
            bestLevels.setRange(0, 16, candidateLevels);
            bestReconstruction.setRange(0, 16, prediction);
          }
        }
        modes[block] = bestMode;
        levels.setRange(
          block * 16,
          block * 16 + 16,
          bestLevels,
        );
        _copyBlock(
          source: bestReconstruction,
          sourceStride: 4,
          destination: reconstruction,
          destinationStride: 16,
          destinationX: blockX * 4,
          destinationY: blockY * 4,
          size: 4,
        );
        candidateTopModes[blockX] = bestMode;
        candidateLeftModes[blockY] = bestMode;
        score += bestScore;
      }
    }
    return _Vp8LumaCandidate(
      isIntra4x4: true,
      modes: modes,
      coefficients: levels,
      reconstruction: reconstruction,
      score: score,
    );
  }

  /// Chooses one shared prediction mode for both chroma planes.
  _Vp8ChromaCandidate _chooseChroma({
    required int macroblockX,
    required int macroblockY,
  }) {
    if (!effort.weighsRateAgainstDistortion) {
      int bestMode = 0;
      int bestError = 1 << 62;
      final Uint8List bluePredictionScratch = Uint8List(8 * 8);
      final Uint8List redPredictionScratch = Uint8List(8 * 8);
      for (int mode = 0; mode < 4; ++mode) {
        final Uint8List bluePrediction = _predictBlock(
          reconstructed: _planes.reconstructedBlueDifference,
          stride: _planes.chromaStride,
          x: macroblockX * 8,
          y: macroblockY * 8,
          size: 8,
          mode: mode,
          output: bluePredictionScratch,
        );
        final Uint8List redPrediction = _predictBlock(
          reconstructed: _planes.reconstructedRedDifference,
          stride: _planes.chromaStride,
          x: macroblockX * 8,
          y: macroblockY * 8,
          size: 8,
          mode: mode,
          output: redPredictionScratch,
        );
        final int sourceOffset = macroblockY * 8 * _planes.chromaStride + macroblockX * 8;
        final int error =
            _blockError(
              source: _planes.blueDifference,
              sourceStride: _planes.chromaStride,
              sourceOffset: sourceOffset,
              candidate: bluePrediction,
              candidateStride: 8,
              size: 8,
            ) +
            _blockError(
              source: _planes.redDifference,
              sourceStride: _planes.chromaStride,
              sourceOffset: sourceOffset,
              candidate: redPrediction,
              candidateStride: 8,
              size: 8,
            );
        if (error < bestError) {
          bestError = error;
          bestMode = mode;
        }
      }
      return _evaluateChroma(
        macroblockX: macroblockX,
        macroblockY: macroblockY,
        mode: bestMode,
      );
    }

    _Vp8ChromaCandidate best = _evaluateChroma(
      macroblockX: macroblockX,
      macroblockY: macroblockY,
      mode: 0,
    );
    for (int mode = 1; mode < 4; ++mode) {
      final _Vp8ChromaCandidate candidate = _evaluateChroma(
        macroblockX: macroblockX,
        macroblockY: macroblockY,
        mode: mode,
      );
      if (candidate.score < best.score) {
        best = candidate;
      }
    }
    return best;
  }

  /// Transforms, quantizes and reconstructs one chroma mode candidate.
  _Vp8ChromaCandidate _evaluateChroma({
    required int macroblockX,
    required int macroblockY,
    required int mode,
  }) {
    final Uint8List bluePrediction = _predictBlock(
      reconstructed: _planes.reconstructedBlueDifference,
      stride: _planes.chromaStride,
      x: macroblockX * 8,
      y: macroblockY * 8,
      size: 8,
      mode: mode,
    );
    final Uint8List redPrediction = _predictBlock(
      reconstructed: _planes.reconstructedRedDifference,
      stride: _planes.chromaStride,
      x: macroblockX * 8,
      y: macroblockY * 8,
      size: 8,
      mode: mode,
    );
    final Uint8List blueReconstruction = Uint8List.fromList(bluePrediction);
    final Uint8List redReconstruction = Uint8List.fromList(redPrediction);
    final Int16List levels = Int16List(8 * 16);
    final Int32List transformedScratch = Int32List(16);
    final Int32List dequantizedScratch = Int32List(16);
    final Int32List inverseScratch = Int32List(16);
    final int sourceOffset = macroblockY * 8 * _planes.chromaStride + macroblockX * 8;
    for (int plane = 0; plane < 2; ++plane) {
      final Uint8List source = plane == 0 ? _planes.blueDifference : _planes.redDifference;
      final Uint8List prediction = plane == 0 ? bluePrediction : redPrediction;
      final Uint8List reconstruction = plane == 0 ? blueReconstruction : redReconstruction;
      for (int blockY = 0; blockY < 2; ++blockY) {
        for (int blockX = 0; blockX < 2; ++blockX) {
          final int block = plane * 4 + blockY * 2 + blockX;
          final Int32List transformed = _Vp8EncoderTransform.forward(
            source,
            sourceOffset: sourceOffset + blockY * 4 * _planes.chromaStride + blockX * 4,
            sourceStride: _planes.chromaStride,
            prediction: prediction,
            predictionOffset: blockY * 4 * 8 + blockX * 4,
            predictionStride: 8,
            output: transformedScratch,
          );
          final Int32List dequantized = _quantize(
            transformed: transformed,
            matrix: _quantizers.chroma,
            levels: levels,
            levelOffset: block * 16,
            firstCoefficient: 0,
            dequantized: dequantizedScratch,
          );
          _Vp8EncoderTransform.inverse(
            dequantized,
            reconstruction,
            destinationOffset: blockY * 4 * 8 + blockX * 4,
            destinationStride: 8,
            scratch: inverseScratch,
          );
        }
      }
    }

    int rate = _chromaModeCost(mode);
    for (int block = 0; block < 8; ++block) {
      rate += _coefficientCost(
        levels,
        offset: block * 16,
        firstCoefficient: 0,
        type: 2,
      );
    }
    final int distortion =
        _blockError(
          source: _planes.blueDifference,
          sourceStride: _planes.chromaStride,
          sourceOffset: sourceOffset,
          candidate: blueReconstruction,
          candidateStride: 8,
          size: 8,
        ) +
        _blockError(
          source: _planes.redDifference,
          sourceStride: _planes.chromaStride,
          sourceOffset: sourceOffset,
          candidate: redReconstruction,
          candidateStride: 8,
          size: 8,
        );
    return _Vp8ChromaCandidate(
      mode: mode,
      coefficients: levels,
      blueDifference: blueReconstruction,
      redDifference: redReconstruction,
      score: distortion * _vp8BitCostUnit + _quantizers.lambda * rate,
    );
  }

  /// Quantizes natural-order transformed coefficients and returns dequantized values.
  Int32List _quantize({
    required Int32List transformed,
    required _Vp8EncoderQuantizationMatrix matrix,
    required Int16List levels,
    required int levelOffset,
    required int firstCoefficient,
    Int32List? dequantized,
    int dequantizedOffset = 0,
  }) {
    final Int32List output = dequantized ?? Int32List(16);
    for (int coefficient = firstCoefficient; coefficient < 16; ++coefficient) {
      final int natural = _Vp8EncoderTables.zigzag[coefficient];
      final int source = transformed[natural];
      final bool negative = source < 0;
      final int sourceMagnitude = source.abs();
      final int sharpenedMagnitude = sourceMagnitude + matrix.sharpening[natural];
      int level = (sharpenedMagnitude * matrix.reciprocals[natural] + matrix.biases[natural]) >> _vp8QuantizerFractionBits;
      level = math.min(level, _vp8MaximumLevel);
      if (effort.refinesCoefficients) {
        final int step = matrix.steps[natural];
        int bestLevel = level;
        int error = sourceMagnitude - level * step;
        int bestScore = error * error * _vp8BitCostUnit + _quantizers.lambda * _Vp8EncoderTables.fixedLevelCosts[level];
        final int firstCandidate = math.max(0, level - 1);
        final int lastCandidate = math.min(_vp8MaximumLevel, level + 1);
        for (int candidate = firstCandidate; candidate <= lastCandidate; ++candidate) {
          if (candidate == level) {
            continue;
          }
          error = sourceMagnitude - candidate * step;
          final int candidateScore = error * error * _vp8BitCostUnit + _quantizers.lambda * _Vp8EncoderTables.fixedLevelCosts[candidate];
          if (candidateScore < bestScore) {
            bestLevel = candidate;
            bestScore = candidateScore;
          }
        }
        level = bestLevel;
      }
      final int signedLevel = negative ? -level : level;
      levels[levelOffset + coefficient] = signedLevel;
      output[dequantizedOffset + natural] = signedLevel * matrix.steps[natural];
    }
    return output;
  }

  /// Builds a macroblock-sized DC, true-motion, vertical, or horizontal prediction.
  static Uint8List _predictBlock({
    required Uint8List reconstructed,
    required int stride,
    required int x,
    required int y,
    required int size,
    required int mode,
    Uint8List? output,
  }) {
    final Uint8List prediction = output ?? Uint8List(size * size);
    final bool hasTop = y > 0;
    final bool hasLeft = x > 0;
    switch (mode) {
      case 0:
        int sum = 0;
        if (hasTop) {
          for (int column = 0; column < size; ++column) {
            sum += reconstructed[(y - 1) * stride + x + column];
          }
        }
        if (hasLeft) {
          for (int row = 0; row < size; ++row) {
            sum += reconstructed[(y + row) * stride + x - 1];
          }
        }
        final int directCurrent = hasTop && hasLeft
            ? (sum + size) ~/ (2 * size)
            : hasTop || hasLeft
            ? (sum + size ~/ 2) ~/ size
            : 128;
        prediction.fillRange(0, prediction.length, directCurrent);
      case 1:
        if (hasTop && hasLeft) {
          final int topLeft = reconstructed[(y - 1) * stride + x - 1];
          for (int row = 0; row < size; ++row) {
            final int left = reconstructed[(y + row) * stride + x - 1];
            for (int column = 0; column < size; ++column) {
              prediction[row * size + column] = _clampByte(
                left + reconstructed[(y - 1) * stride + x + column] - topLeft,
              );
            }
          }
        } else if (hasLeft) {
          _fillHorizontal(
            prediction: prediction,
            reconstructed: reconstructed,
            stride: stride,
            x: x,
            y: y,
            size: size,
          );
        } else if (hasTop) {
          _fillVertical(
            prediction: prediction,
            reconstructed: reconstructed,
            stride: stride,
            x: x,
            y: y,
            size: size,
          );
        } else {
          prediction.fillRange(0, prediction.length, 129);
        }
      case 2:
        if (hasTop) {
          _fillVertical(
            prediction: prediction,
            reconstructed: reconstructed,
            stride: stride,
            x: x,
            y: y,
            size: size,
          );
        } else {
          prediction.fillRange(0, prediction.length, 127);
        }
      case 3:
        if (hasLeft) {
          _fillHorizontal(
            prediction: prediction,
            reconstructed: reconstructed,
            stride: stride,
            x: x,
            y: y,
            size: size,
          );
        } else {
          prediction.fillRange(0, prediction.length, 129);
        }
      default:
        throw StateError('Invalid VP8 prediction mode: $mode');
    }
    return prediction;
  }

  /// Reads the boundary samples visible to one four-by-four luma block.
  (int, int) _readLuma4Boundary({
    required int macroblockX,
    required int macroblockY,
    required int blockX,
    required int blockY,
    required Uint8List macroblockReconstruction,
    required Uint8List top,
    required Uint8List left,
  }) {
    final int globalX = macroblockX * 16 + blockX * 4;
    final int globalY = macroblockY * 16 + blockY * 4;
    for (int index = 0; index < 4; ++index) {
      top[index] = blockY > 0
          ? macroblockReconstruction[(blockY * 4 - 1) * 16 + blockX * 4 + index]
          : globalY > 0
          ? _planes.reconstructedLuma[(globalY - 1) * _planes.lumaStride + globalX + index]
          : 127;
      left[index] = blockX > 0
          ? macroblockReconstruction[(blockY * 4 + index) * 16 + blockX * 4 - 1]
          : globalX > 0
          ? _planes.reconstructedLuma[(globalY + index) * _planes.lumaStride + globalX - 1]
          : 129;
    }
    final int topLeft = blockX > 0 && blockY > 0
        ? macroblockReconstruction[(blockY * 4 - 1) * 16 + blockX * 4 - 1]
        : globalX > 0 && globalY > 0
        ? _planes.reconstructedLuma[(globalY - 1) * _planes.lumaStride + globalX - 1]
        : globalY == 0
        ? 127
        : 129;
    final int topRight = _luma4TopRight(
      macroblockX: macroblockX,
      macroblockY: macroblockY,
      blockX: blockX,
      blockY: blockY,
      macroblockReconstruction: macroblockReconstruction,
    );
    return (topLeft, topRight);
  }

  /// Builds a basic four-by-four prediction from prepared boundary samples.
  static void _predictLuma4({
    required Uint8List top,
    required Uint8List left,
    required int topLeft,
    required int topRight,
    required int mode,
    required Uint8List prediction,
  }) {
    switch (mode) {
      case 0:
        int sum = 4;
        for (int index = 0; index < 4; ++index) {
          sum += top[index] + left[index];
        }
        prediction.fillRange(0, prediction.length, sum >> 3);
      case 1:
        for (int row = 0; row < 4; ++row) {
          for (int column = 0; column < 4; ++column) {
            prediction[row * 4 + column] = _clampByte(
              left[row] + top[column] - topLeft,
            );
          }
        }
      case 2:
        final int filtered0 = _averageThree(topLeft, top[0], top[1]);
        final int filtered1 = _averageThree(top[0], top[1], top[2]);
        final int filtered2 = _averageThree(top[1], top[2], top[3]);
        final int filtered3 = _averageThree(top[2], top[3], topRight);
        for (int row = 0; row < 4; ++row) {
          final int rowOffset = row * 4;
          prediction[rowOffset] = filtered0;
          prediction[rowOffset + 1] = filtered1;
          prediction[rowOffset + 2] = filtered2;
          prediction[rowOffset + 3] = filtered3;
        }
      case 3:
        prediction.fillRange(
          0,
          4,
          _averageThree(topLeft, left[0], left[1]),
        );
        prediction.fillRange(
          4,
          8,
          _averageThree(left[0], left[1], left[2]),
        );
        prediction.fillRange(
          8,
          12,
          _averageThree(left[1], left[2], left[3]),
        );
        prediction.fillRange(
          12,
          16,
          _averageThree(left[2], left[3], left[3]),
        );
      default:
        throw StateError('Invalid VP8 four-by-four mode: $mode');
    }
  }

  /// Returns the first top-right sample visible to one luma block.
  int _luma4TopRight({
    required int macroblockX,
    required int macroblockY,
    required int blockX,
    required int blockY,
    required Uint8List macroblockReconstruction,
  }) {
    if (blockX < 3) {
      if (blockY > 0) {
        return macroblockReconstruction[(blockY * 4 - 1) * 16 + blockX * 4 + 4];
      }
      if (macroblockY == 0) {
        return 127;
      }
      return _planes.reconstructedLuma[(macroblockY * 16 - 1) * _planes.lumaStride + macroblockX * 16 + blockX * 4 + 4];
    }
    if (macroblockY == 0) {
      return 127;
    }
    if (macroblockX == _macroblockWidth - 1) {
      return _planes.reconstructedLuma[(macroblockY * 16 - 1) * _planes.lumaStride + macroblockX * 16 + 15];
    }
    return _planes.reconstructedLuma[(macroblockY * 16 - 1) * _planes.lumaStride + (macroblockX + 1) * 16];
  }

  /// Applies VP8's three-sample one-two-one prediction filter.
  static int _averageThree(int first, int middle, int third) => (first + 2 * middle + third + 2) >> 2;

  /// Copies the top reference row into every prediction row.
  static void _fillVertical({
    required Uint8List prediction,
    required Uint8List reconstructed,
    required int stride,
    required int x,
    required int y,
    required int size,
  }) {
    final int top = (y - 1) * stride + x;
    for (int row = 0; row < size; ++row) {
      prediction.setRange(
        row * size,
        row * size + size,
        reconstructed,
        top,
      );
    }
  }

  /// Copies each left reference sample across one prediction row.
  static void _fillHorizontal({
    required Uint8List prediction,
    required Uint8List reconstructed,
    required int stride,
    required int x,
    required int y,
    required int size,
  }) {
    for (int row = 0; row < size; ++row) {
      prediction.fillRange(
        row * size,
        row * size + size,
        reconstructed[(y + row) * stride + x - 1],
      );
    }
  }

  /// Returns the squared error between a plane block and a compact candidate.
  static int _blockError({
    required Uint8List source,
    required int sourceStride,
    required int sourceOffset,
    required Uint8List candidate,
    required int candidateStride,
    required int size,
  }) {
    int error = 0;
    for (int row = 0; row < size; ++row) {
      for (int column = 0; column < size; ++column) {
        final int difference = source[sourceOffset + row * sourceStride + column] - candidate[row * candidateStride + column];
        error += difference * difference;
      }
    }
    return error;
  }

  /// Copies one compact square block into a larger plane.
  static void _copyBlock({
    required Uint8List source,
    required int sourceStride,
    required Uint8List destination,
    required int destinationStride,
    required int destinationX,
    required int destinationY,
    required int size,
  }) {
    for (int row = 0; row < size; ++row) {
      destination.setRange(
        (destinationY + row) * destinationStride + destinationX,
        (destinationY + row) * destinationStride + destinationX + size,
        source,
        row * sourceStride,
      );
    }
  }

  /// Clamps one reconstructed sample to an unsigned byte.
  static int _clampByte(int value) => value < 0
      ? 0
      : value > 255
      ? 255
      : value;

  /// Returns the arithmetic-code cost of one sixteen-by-sixteen luma mode.
  static int _intra16ModeCost(int mode) => switch (mode) {
    0 => _Vp8EncoderTables.zeroCost(156) + _Vp8EncoderTables.zeroCost(163),
    1 => _Vp8EncoderTables.oneCost(156) + _Vp8EncoderTables.oneCost(128),
    2 => _Vp8EncoderTables.zeroCost(156) + _Vp8EncoderTables.oneCost(163),
    3 => _Vp8EncoderTables.oneCost(156) + _Vp8EncoderTables.zeroCost(128),
    _ => throw StateError('Invalid VP8 luma mode: $mode'),
  };

  /// Returns the context-dependent arithmetic-code cost of one luma4 mode.
  static int _intra4ModeCost({
    required int topMode,
    required int leftMode,
    required int mode,
  }) {
    final List<int> probabilities = _Vp8Decoder._intra4ModeProbabilities[topMode][leftMode];
    final Uint8List nodes = _Vp8EncoderTables.intra4PathNodes[mode];
    final Uint8List bits = _Vp8EncoderTables.intra4PathBits[mode];
    int cost = 0;
    for (int index = 0; index < nodes.length; ++index) {
      cost += _Vp8EncoderTables.bitCost(
        bits[index],
        probabilities[nodes[index]],
      );
    }
    return cost;
  }

  /// Returns the arithmetic-code cost of one chroma mode.
  static int _chromaModeCost(int mode) => switch (mode) {
    0 => _Vp8EncoderTables.zeroCost(142),
    1 => _Vp8EncoderTables.oneCost(142) + _Vp8EncoderTables.oneCost(114) + _Vp8EncoderTables.oneCost(183),
    2 => _Vp8EncoderTables.oneCost(142) + _Vp8EncoderTables.zeroCost(114),
    3 => _Vp8EncoderTables.oneCost(142) + _Vp8EncoderTables.oneCost(114) + _Vp8EncoderTables.zeroCost(183),
    _ => throw StateError('Invalid VP8 chroma mode: $mode'),
  };

  /// Estimates one residual block with the default coefficient probabilities.
  static int _coefficientCost(
    Int16List coefficients, {
    required int offset,
    required int firstCoefficient,
    required int type,
  }) {
    final Uint8List probabilities = _Vp8EncoderTables.defaultProbabilities;
    int last = 15;
    while (last >= firstCoefficient && coefficients[offset + last] == 0) {
      --last;
    }
    int probabilityIndex = _vp8ProbabilityIndex(
      type,
      _Vp8EncoderTables.bands[firstCoefficient],
      0,
      0,
    );
    int cost = _Vp8EncoderTables.bitCost(
      last >= firstCoefficient ? 1 : 0,
      probabilities[probabilityIndex],
    );
    if (last < firstCoefficient) {
      return cost;
    }

    int coefficient = firstCoefficient;
    while (coefficient < 16) {
      final int magnitude = coefficients[offset + coefficient].abs();
      cost += _Vp8EncoderTables.bitCost(
        magnitude != 0 ? 1 : 0,
        probabilities[probabilityIndex + 1],
      );
      ++coefficient;
      if (magnitude == 0) {
        probabilityIndex = _vp8ProbabilityIndex(
          type,
          _Vp8EncoderTables.bands[coefficient],
          0,
          0,
        );
        continue;
      }

      cost += _Vp8EncoderTables.bitCost(
        magnitude > 1 ? 1 : 0,
        probabilities[probabilityIndex + 2],
      );
      if (magnitude > 1) {
        if (magnitude <= 4) {
          cost += _Vp8EncoderTables.zeroCost(
            probabilities[probabilityIndex + 3],
          );
          cost += _Vp8EncoderTables.bitCost(
            magnitude != 2 ? 1 : 0,
            probabilities[probabilityIndex + 4],
          );
          if (magnitude != 2) {
            cost += _Vp8EncoderTables.bitCost(
              magnitude == 4 ? 1 : 0,
              probabilities[probabilityIndex + 5],
            );
          }
        } else if (magnitude <= 10) {
          cost += _Vp8EncoderTables.oneCost(
            probabilities[probabilityIndex + 3],
          );
          cost += _Vp8EncoderTables.zeroCost(
            probabilities[probabilityIndex + 6],
          );
          cost += _Vp8EncoderTables.bitCost(
            magnitude > 6 ? 1 : 0,
            probabilities[probabilityIndex + 7],
          );
        } else {
          cost += _Vp8EncoderTables.oneCost(
            probabilities[probabilityIndex + 3],
          );
          cost += _Vp8EncoderTables.oneCost(
            probabilities[probabilityIndex + 6],
          );
          final (List<int> category, _, _) = _Vp8EncoderTables.categoryOf(
            magnitude,
          );
          final bool highCategory = category.length >= 5;
          cost += _Vp8EncoderTables.bitCost(
            highCategory ? 1 : 0,
            probabilities[probabilityIndex + 8],
          );
          cost += _Vp8EncoderTables.bitCost(
            highCategory
                ? category.length == 11
                      ? 1
                      : 0
                : category.length == 4
                ? 1
                : 0,
            probabilities[probabilityIndex + (highCategory ? 10 : 9)],
          );
        }
      }
      cost += _Vp8EncoderTables.fixedLevelCosts[magnitude];
      probabilityIndex = _vp8ProbabilityIndex(
        type,
        _Vp8EncoderTables.bands[coefficient],
        magnitude == 1 ? 1 : 2,
        0,
      );
      if (coefficient == 16) {
        return cost;
      }
      final int hasMore = coefficient <= last ? 1 : 0;
      cost += _Vp8EncoderTables.bitCost(
        hasMore,
        probabilities[probabilityIndex],
      );
      if (hasMore == 0) {
        return cost;
      }
    }
    return cost;
  }

  /// Walks every residual in decoder order while maintaining neighbor contexts.
  void _visitResiduals({
    required bool honorSkip,
    required _Vp8ResidualVisitor visitor,
  }) {
    final Uint8List topLuma = Uint8List(_macroblockWidth * 4);
    final Uint8List topBlue = Uint8List(_macroblockWidth * 2);
    final Uint8List topRed = Uint8List(_macroblockWidth * 2);
    final Uint8List topSecondary = Uint8List(_macroblockWidth);
    final Uint8List leftLuma = Uint8List(4);
    final Uint8List leftBlue = Uint8List(2);
    final Uint8List leftRed = Uint8List(2);
    int leftSecondary = 0;
    for (int macroblockY = 0; macroblockY < _macroblockHeight; ++macroblockY) {
      leftLuma.fillRange(0, leftLuma.length, 0);
      leftBlue.fillRange(0, leftBlue.length, 0);
      leftRed.fillRange(0, leftRed.length, 0);
      leftSecondary = 0;
      for (int macroblockX = 0; macroblockX < _macroblockWidth; ++macroblockX) {
        final _Vp8LossyMacroblock macroblock = _macroblocks[macroblockY * _macroblockWidth + macroblockX];
        final int topLumaOffset = macroblockX * 4;
        final int topChromaOffset = macroblockX * 2;
        if (honorSkip && macroblock.skip) {
          topLuma.fillRange(topLumaOffset, topLumaOffset + 4, 0);
          topBlue.fillRange(topChromaOffset, topChromaOffset + 2, 0);
          topRed.fillRange(topChromaOffset, topChromaOffset + 2, 0);
          leftLuma.fillRange(0, leftLuma.length, 0);
          leftBlue.fillRange(0, leftBlue.length, 0);
          leftRed.fillRange(0, leftRed.length, 0);
          if (!macroblock.isIntra4x4) {
            topSecondary[macroblockX] = 0;
            leftSecondary = 0;
          }
          continue;
        }

        if (!macroblock.isIntra4x4) {
          final int nonZero = visitor(
            macroblock,
            _vp8SecondaryLumaCoefficientOffset,
            0,
            1,
            topSecondary[macroblockX] + leftSecondary,
          );
          topSecondary[macroblockX] = nonZero;
          leftSecondary = nonZero;
        }
        for (int blockY = 0; blockY < 4; ++blockY) {
          for (int blockX = 0; blockX < 4; ++blockX) {
            final int nonZero = visitor(
              macroblock,
              (blockY * 4 + blockX) * 16,
              macroblock.isIntra4x4 ? 0 : 1,
              macroblock.isIntra4x4 ? 3 : 0,
              topLuma[topLumaOffset + blockX] + leftLuma[blockY],
            );
            topLuma[topLumaOffset + blockX] = nonZero;
            leftLuma[blockY] = nonZero;
          }
        }
        for (int plane = 0; plane < 2; ++plane) {
          final Uint8List top = plane == 0 ? topBlue : topRed;
          final Uint8List left = plane == 0 ? leftBlue : leftRed;
          for (int blockY = 0; blockY < 2; ++blockY) {
            for (int blockX = 0; blockX < 2; ++blockX) {
              final int block = plane * 4 + blockY * 2 + blockX;
              final int nonZero = visitor(
                macroblock,
                _vp8ChromaCoefficientOffset + block * 16,
                0,
                2,
                top[topChromaOffset + blockX] + left[blockY],
              );
              top[topChromaOffset + blockX] = nonZero;
              left[blockY] = nonZero;
            }
          }
        }
      }
    }
  }

  /// Walks one coefficient tree, optionally writing bits or collecting counts.
  static (int, int) _walkCoefficients({
    required Int16List coefficients,
    required int coefficientOffset,
    required int firstCoefficient,
    required int type,
    required int context,
    required Uint8List probabilities,
    _Vp8BitWriter? writer,
    Int32List? statistics,
  }) {
    int last = 15;
    while (last >= firstCoefficient && coefficients[coefficientOffset + last] == 0) {
      --last;
    }
    int cost = 0;
    int probabilityIndex = _vp8ProbabilityIndex(
      type,
      _Vp8EncoderTables.bands[firstCoefficient],
      context,
      0,
    );

    /// Records or writes one probability-driven tree decision.
    void decision(int bit, int index) {
      writer?.writeBit(bit, probabilities[index]);
      statistics?[index * 2 + bit]++;
      cost += _Vp8EncoderTables.bitCost(bit, probabilities[index]);
    }

    /// Records or writes one equiprobable decision.
    void uniform(int bit) {
      writer?.writeUniformBit(bit);
      cost += _vp8BitCostUnit;
    }

    decision(last >= firstCoefficient ? 1 : 0, probabilityIndex);
    if (last < firstCoefficient) {
      return (0, cost);
    }
    int coefficient = firstCoefficient;
    while (coefficient < 16) {
      final int signedLevel = coefficients[coefficientOffset + coefficient];
      final int magnitude = signedLevel.abs();
      decision(magnitude != 0 ? 1 : 0, probabilityIndex + 1);
      ++coefficient;
      if (magnitude == 0) {
        probabilityIndex = _vp8ProbabilityIndex(
          type,
          _Vp8EncoderTables.bands[coefficient],
          0,
          0,
        );
        continue;
      }
      decision(magnitude > 1 ? 1 : 0, probabilityIndex + 2);
      if (magnitude > 1) {
        if (magnitude <= 4) {
          decision(0, probabilityIndex + 3);
          decision(magnitude != 2 ? 1 : 0, probabilityIndex + 4);
          if (magnitude != 2) {
            decision(magnitude == 4 ? 1 : 0, probabilityIndex + 5);
          }
        } else if (magnitude <= 10) {
          decision(1, probabilityIndex + 3);
          decision(0, probabilityIndex + 6);
          decision(magnitude > 6 ? 1 : 0, probabilityIndex + 7);
          if (magnitude <= 6) {
            writer?.writeBit(magnitude == 6 ? 1 : 0, 159);
            cost += _Vp8EncoderTables.bitCost(
              magnitude == 6 ? 1 : 0,
              159,
            );
          } else {
            writer?.writeBit(magnitude >= 9 ? 1 : 0, 165);
            writer?.writeBit(magnitude.isEven ? 1 : 0, 145);
            cost += _Vp8EncoderTables.bitCost(
              magnitude >= 9 ? 1 : 0,
              165,
            );
            cost += _Vp8EncoderTables.bitCost(
              magnitude.isEven ? 1 : 0,
              145,
            );
          }
        } else {
          decision(1, probabilityIndex + 3);
          decision(1, probabilityIndex + 6);
          final (List<int> category, int mask, int residue) = _Vp8EncoderTables.categoryOf(magnitude);
          final bool highCategory = category.length >= 5;
          decision(highCategory ? 1 : 0, probabilityIndex + 8);
          if (highCategory) {
            decision(category.length == 11 ? 1 : 0, probabilityIndex + 10);
          } else {
            decision(category.length == 4 ? 1 : 0, probabilityIndex + 9);
          }
          int bit = mask;
          int categoryIndex = 0;
          while (bit != 0) {
            final int value = (residue & bit) != 0 ? 1 : 0;
            writer?.writeBit(value, category[categoryIndex]);
            cost += _Vp8EncoderTables.bitCost(
              value,
              category[categoryIndex],
            );
            bit >>= 1;
            ++categoryIndex;
          }
        }
      }
      uniform(signedLevel < 0 ? 1 : 0);
      probabilityIndex = _vp8ProbabilityIndex(
        type,
        _Vp8EncoderTables.bands[coefficient],
        magnitude == 1 ? 1 : 2,
        0,
      );
      if (coefficient == 16) {
        return (1, cost);
      }
      final int hasMore = coefficient <= last ? 1 : 0;
      decision(hasMore, probabilityIndex);
      if (hasMore == 0) {
        return (1, cost);
      }
    }
    return (1, cost);
  }

  /// Selects coefficient probabilities when their update overhead is repaid.
  static Uint8List _selectProbabilities(Int32List statistics) {
    final Uint8List selected = Uint8List.fromList(
      _Vp8EncoderTables.defaultProbabilities,
    );
    for (int index = 0; index < _vp8ProbabilityTotal; ++index) {
      final int zeroCount = statistics[index * 2];
      final int oneCount = statistics[index * 2 + 1];
      final int total = zeroCount + oneCount;
      if (total == 0) {
        continue;
      }
      final int candidate = ((255 * zeroCount + total ~/ 2) ~/ total).clamp(1, 255);
      final int original = selected[index];
      final int updateProbability = _Vp8EncoderTables.updateProbabilities[index];
      final int originalCost = _Vp8EncoderTables.zeroCost(updateProbability) + zeroCount * _Vp8EncoderTables.zeroCost(original) + oneCount * _Vp8EncoderTables.oneCost(original);
      final int candidateCost =
          _Vp8EncoderTables.oneCost(updateProbability) + 8 * _vp8BitCostUnit + zeroCount * _Vp8EncoderTables.zeroCost(candidate) + oneCount * _Vp8EncoderTables.oneCost(candidate);
      if (candidateCost < originalCost) {
        selected[index] = candidate;
      }
    }
    return selected;
  }

  /// Writes frame configuration, coefficient updates, skip flags and modes.
  Uint8List _writePartitionZero(Uint8List probabilities) {
    final _Vp8BitWriter writer = _Vp8BitWriter()
      ..writeUniformBit(0)
      ..writeUniformBit(0)
      ..writeUniformBit(0)
      ..writeUniformBit(1)
      ..writeBits(_filterLevel, 6)
      ..writeBits(0, 3)
      ..writeUniformBit(0)
      ..writeBits(0, 2)
      ..writeBits(_quantizers.index, 7)
      ..writeSignedBits(0, 4)
      ..writeSignedBits(0, 4)
      ..writeSignedBits(0, 4)
      ..writeSignedBits(0, 4)
      ..writeSignedBits(0, 4)
      ..writeUniformBit(0);
    for (int index = 0; index < _vp8ProbabilityTotal; ++index) {
      final bool update = probabilities[index] != _Vp8EncoderTables.defaultProbabilities[index];
      writer.writeOptionalByte(
        update,
        probabilities[index],
        _Vp8EncoderTables.updateProbabilities[index],
      );
    }
    writer.writeUniformBit(_usesSkipProbability ? 1 : 0);
    if (_usesSkipProbability) {
      writer.writeBits(_skipProbability, 8);
    }
    _writeModes(writer);
    final Uint8List bytes = writer.finish();
    if (bytes.length >= 1 << 19) {
      throw const ImageCodecException(
        'Lossy WebP mode partition exceeds the VP8 size limit',
      );
    }
    return bytes;
  }

  /// Writes macroblock skip and prediction-mode syntax in raster order.
  void _writeModes(_Vp8BitWriter writer) {
    final Uint8List topModes = Uint8List(_macroblockWidth * 4);
    final Uint8List leftModes = Uint8List(4);
    for (int macroblockY = 0; macroblockY < _macroblockHeight; ++macroblockY) {
      leftModes.fillRange(0, leftModes.length, 0);
      for (int macroblockX = 0; macroblockX < _macroblockWidth; ++macroblockX) {
        final _Vp8LossyMacroblock macroblock = _macroblocks[macroblockY * _macroblockWidth + macroblockX];
        if (_usesSkipProbability) {
          writer.writeBit(
            macroblock.skip ? 1 : 0,
            _skipProbability,
          );
        }
        writer.writeBit(macroblock.isIntra4x4 ? 0 : 1, 145);
        final int topOffset = macroblockX * 4;
        if (macroblock.isIntra4x4) {
          for (int blockY = 0; blockY < 4; ++blockY) {
            int leftMode = leftModes[blockY];
            for (int blockX = 0; blockX < 4; ++blockX) {
              final int mode = macroblock.lumaModes[blockY * 4 + blockX];
              final List<int> modeProbabilities = _Vp8Decoder._intra4ModeProbabilities[topModes[topOffset + blockX]][leftMode];
              final Uint8List nodes = _Vp8EncoderTables.intra4PathNodes[mode];
              final Uint8List bits = _Vp8EncoderTables.intra4PathBits[mode];
              for (int index = 0; index < nodes.length; ++index) {
                writer.writeBit(
                  bits[index],
                  modeProbabilities[nodes[index]],
                );
              }
              topModes[topOffset + blockX] = mode;
              leftMode = mode;
            }
            leftModes[blockY] = leftMode;
          }
        } else {
          final int mode = macroblock.lumaModes[0];
          if (writer.writeBit(mode == 1 || mode == 3 ? 1 : 0, 156) != 0) {
            writer.writeBit(mode == 1 ? 1 : 0, 128);
          } else {
            writer.writeBit(mode == 2 ? 1 : 0, 163);
          }
          topModes.fillRange(topOffset, topOffset + 4, mode);
          leftModes.fillRange(0, leftModes.length, mode);
        }
        final int chromaMode = macroblock.chromaMode;
        if (writer.writeBit(chromaMode == 0 ? 0 : 1, 142) != 0 && writer.writeBit(chromaMode == 2 ? 0 : 1, 114) != 0) {
          writer.writeBit(chromaMode == 1 ? 1 : 0, 183);
        }
      }
    }
  }

  /// Writes all non-skipped coefficient blocks to the token partition.
  Uint8List _writeTokenPartition(Uint8List probabilities) {
    final _Vp8BitWriter writer = _Vp8BitWriter();
    _visitResiduals(
      honorSkip: _usesSkipProbability,
      visitor: (macroblock, coefficientOffset, firstCoefficient, type, context) => _walkCoefficients(
        coefficients: macroblock.coefficients,
        coefficientOffset: coefficientOffset,
        firstCoefficient: firstCoefficient,
        type: type,
        context: context,
        probabilities: probabilities,
        writer: writer,
      ).$1,
    );
    return writer.finish();
  }

  /// Derives a conservative simple-filter strength from the quantizer.
  int get _filterLevel => _quantizers.index == 0 ? 0 : ((_quantizers.index * 3) >> 3).clamp(1, 63);

  /// Prepends the uncompressed key-frame header to both compressed partitions.
  Uint8List _assembleVp8({
    required Uint8List partitionZero,
    required Uint8List tokenPartition,
  }) {
    final OutputBuffer output = OutputBuffer();
    final int frameTag = 0x10 | (partitionZero.length << 5);
    output
      ..writeByte(frameTag)
      ..writeByte(frameTag >> 8)
      ..writeByte(frameTag >> 16)
      ..writeByte(0x9d)
      ..writeByte(0x01)
      ..writeByte(0x2a)
      ..writeUint16(_width)
      ..writeUint16(_height)
      ..writeBytes(partitionZero)
      ..writeBytes(tokenPartition);
    return output.takeBytes();
  }

  /// Wraps VP8 data and optional raw alpha in their ordered RIFF chunks.
  Uint8List _wrapContainer(Uint8List vp8) {
    final Uint8List? alpha = _planes.alpha;
    final int alphaLength = alpha == null ? 0 : alpha.length + 1;
    final int riffSize = 4 + (alpha == null ? 0 : 8 + 10) + (alpha == null ? 0 : 8 + alphaLength + (alphaLength & 1)) + 8 + vp8.length + (vp8.length & 1);
    final OutputBuffer output = OutputBuffer()
      ..writeBytes(_riffTag('RIFF'))
      ..writeUint32(riffSize)
      ..writeBytes(_riffTag('WEBP'));
    if (alpha != null) {
      output
        ..writeBytes(_riffTag('VP8X'))
        ..writeUint32(10)
        ..writeUint32(0x10);
      _writeUint24(output, _width - 1);
      _writeUint24(output, _height - 1);
      output
        ..writeBytes(_riffTag('ALPH'))
        ..writeUint32(alphaLength)
        ..writeByte(0)
        ..writeBytes(alpha);
      if (alphaLength.isOdd) {
        output.writeByte(0);
      }
    }
    output
      ..writeBytes(_riffTag('VP8 '))
      ..writeUint32(vp8.length)
      ..writeBytes(vp8);
    if (vp8.length.isOdd) {
      output.writeByte(0);
    }
    return output.takeBytes();
  }

  /// Encodes one four-character RIFF tag.
  static Uint8List _riffTag(String value) => Uint8List.fromList(value.codeUnits);

  /// Writes a little-endian 24-bit integer.
  static void _writeUint24(OutputBuffer output, int value) {
    output
      ..writeByte(value)
      ..writeByte(value >> 8)
      ..writeByte(value >> 16);
  }
}
