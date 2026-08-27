part of '../../webp.dart';

/// Reconstructs lossy VP8 blocks and applies their in-loop filters.
final class _Vp8Filter {
  /// Prediction functions for 4 by 4 luma blocks.
  static const List<void Function(_WebPBuffer destination)> luma4Predictors = [
    _predictDirectCurrent4,
    _predictTrueMotion4,
    _predictVertical4,
    _predictHorizontal4,
    _predictDownRight4,
    _predictVerticalRight4,
    _predictDownLeft4,
    _predictVerticalLeft4,
    _predictHorizontalDown4,
    _predictHorizontalUp4,
  ];

  /// Prediction functions for 16 by 16 luma blocks.
  static const List<void Function(_WebPBuffer destination)> luma16Predictors = [
    _predictDirectCurrentLuma,
    _predictTrueMotionLuma,
    _predictVerticalLuma16,
    _predictHorizontalLuma16,
    _predictDirectCurrentLumaWithoutTop,
    _predictDirectCurrentLumaWithoutLeft,
    _predictDirectCurrentLumaWithoutNeighbors,
  ];

  /// Prediction functions for 8 by 8 chroma blocks.
  static const List<void Function(_WebPBuffer destination)> chroma8Predictors = [
    _predictDirectCurrentChroma,
    _predictTrueMotionChroma,
    _predictVerticalChroma,
    _predictHorizontalChroma,
    _predictDirectCurrentChromaWithoutTop,
    _predictDirectCurrentChromaWithoutLeft,
    _predictDirectCurrentChromaWithoutNeighbors,
  ];

  /// First fixed-point inverse-transform coefficient.
  static const int _transformCoefficient1 = 20091 + (1 << 16);

  /// Second fixed-point inverse-transform coefficient.
  static const int _transformCoefficient2 = 35468;

  /// Absolute-value lookup indexed around zero.
  static final Uint8List _absolute = Uint8List(511);

  /// Half-absolute-value lookup indexed around zero.
  static final Uint8List _halfAbsolute = Uint8List(511);

  /// Lookup that clips values from -1020 through 1020 to signed bytes.
  static final Int8List _wideSignedClip = Int8List(2041);

  /// Lookup that clips values from -112 through 112 to -16 through 15.
  static final Int8List _narrowSignedClip = Int8List(225);

  /// Lookup that clips values from -255 through 510 to unsigned bytes.
  static final Uint8List _unsignedClip = Uint8List(766);

  /// Whether the shared clipping tables have been populated.
  static bool _tablesInitialized = false;

  /// Creates a filter and initializes its shared clipping tables.
  _Vp8Filter() {
    _initTables();
  }

  /// Applies the simple filter to a vertical luma macroblock edge.
  void filterSimpleVerticalLumaEdge(
    _WebPBuffer pixels,
    int stride,
    int threshold,
  ) {
    final _WebPBuffer currentPixel = _WebPBuffer.from(source: pixels);
    for (int index = 0; index < 16; ++index) {
      currentPixel.offset = pixels.offset + index;
      if (_needsFilter(currentPixel, stride, threshold)) {
        _filterTwoSamples(currentPixel, stride);
      }
    }
  }

  /// Applies the simple filter to a horizontal luma macroblock edge.
  void filterSimpleHorizontalLumaEdge(
    _WebPBuffer pixels,
    int stride,
    int threshold,
  ) {
    final _WebPBuffer currentPixel = _WebPBuffer.from(source: pixels);
    for (int index = 0; index < 16; ++index) {
      currentPixel.offset = pixels.offset + index * stride;
      if (_needsFilter(currentPixel, 1, threshold)) {
        _filterTwoSamples(currentPixel, 1);
      }
    }
  }

  /// Applies the simple vertical filter to the three inner luma edges.
  void filterSimpleVerticalLumaInterior(
    _WebPBuffer pixels,
    int stride,
    int threshold,
  ) {
    final _WebPBuffer currentEdge = _WebPBuffer.from(source: pixels);
    for (int edge = 3; edge > 0; --edge) {
      currentEdge.offset += 4 * stride;
      filterSimpleVerticalLumaEdge(currentEdge, stride, threshold);
    }
  }

  /// Applies the simple horizontal filter to the three inner luma edges.
  void filterSimpleHorizontalLumaInterior(
    _WebPBuffer pixels,
    int stride,
    int threshold,
  ) {
    final _WebPBuffer currentEdge = _WebPBuffer.from(source: pixels);
    for (int edge = 3; edge > 0; --edge) {
      currentEdge.offset += 4;
      filterSimpleHorizontalLumaEdge(currentEdge, stride, threshold);
    }
  }

  /// Applies the normal filter to a vertical luma macroblock edge.
  void filterVerticalLumaEdge(
    _WebPBuffer pixels,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    _filterWideEdge(
      pixels,
      stride,
      1,
      16,
      threshold,
      interiorThreshold,
      highEdgeVarianceThreshold,
    );
  }

  /// Applies the normal filter to a horizontal luma macroblock edge.
  void filterHorizontalLumaEdge(
    _WebPBuffer pixels,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    _filterWideEdge(
      pixels,
      1,
      stride,
      16,
      threshold,
      interiorThreshold,
      highEdgeVarianceThreshold,
    );
  }

  /// Applies the normal vertical filter to the three inner luma edges.
  void filterVerticalLumaInterior(
    _WebPBuffer pixels,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    final _WebPBuffer currentEdge = _WebPBuffer.from(source: pixels);
    for (int edge = 3; edge > 0; --edge) {
      currentEdge.offset += 4 * stride;
      _filterNarrowEdge(
        currentEdge,
        stride,
        1,
        16,
        threshold,
        interiorThreshold,
        highEdgeVarianceThreshold,
      );
    }
  }

  /// Applies the normal horizontal filter to the three inner luma edges.
  void filterHorizontalLumaInterior(
    _WebPBuffer pixels,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    final _WebPBuffer currentEdge = _WebPBuffer.from(source: pixels);
    for (int edge = 3; edge > 0; --edge) {
      currentEdge.offset += 4;
      _filterNarrowEdge(
        currentEdge,
        1,
        stride,
        16,
        threshold,
        interiorThreshold,
        highEdgeVarianceThreshold,
      );
    }
  }

  /// Applies the normal filter to vertical chroma macroblock edges.
  void filterVerticalChromaEdge(
    _WebPBuffer blueDifference,
    _WebPBuffer redDifference,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    _filterWideEdge(blueDifference, stride, 1, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
    _filterWideEdge(redDifference, stride, 1, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
  }

  /// Applies the normal filter to horizontal chroma macroblock edges.
  void filterHorizontalChromaEdge(
    _WebPBuffer blueDifference,
    _WebPBuffer redDifference,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    _filterWideEdge(blueDifference, 1, stride, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
    _filterWideEdge(redDifference, 1, stride, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
  }

  /// Applies the normal vertical filter to the inner chroma edges.
  void filterVerticalChromaInterior(
    _WebPBuffer blueDifference,
    _WebPBuffer redDifference,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    final _WebPBuffer blueEdge = _WebPBuffer.from(source: blueDifference, offset: 4 * stride);
    final _WebPBuffer redEdge = _WebPBuffer.from(source: redDifference, offset: 4 * stride);
    _filterNarrowEdge(blueEdge, stride, 1, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
    _filterNarrowEdge(redEdge, stride, 1, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
  }

  /// Applies the normal horizontal filter to the inner chroma edges.
  void filterHorizontalChromaInterior(
    _WebPBuffer blueDifference,
    _WebPBuffer redDifference,
    int stride,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    final _WebPBuffer blueEdge = _WebPBuffer.from(source: blueDifference, offset: 4);
    final _WebPBuffer redEdge = _WebPBuffer.from(source: redDifference, offset: 4);
    _filterNarrowEdge(blueEdge, 1, stride, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
    _filterNarrowEdge(redEdge, 1, stride, 8, threshold, interiorThreshold, highEdgeVarianceThreshold);
  }

  /// Filters an edge with either the two-sample or six-sample kernel.
  void _filterWideEdge(
    _WebPBuffer pixels,
    int sampleStride,
    int edgeStride,
    int length,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    final _WebPBuffer currentPixel = _WebPBuffer.from(source: pixels);
    int remaining = length;
    while (remaining-- > 0) {
      if (_needsWideFilter(currentPixel, sampleStride, threshold, interiorThreshold)) {
        if (_hasHighEdgeVariance(currentPixel, sampleStride, highEdgeVarianceThreshold)) {
          _filterTwoSamples(currentPixel, sampleStride);
        } else {
          _filterSixSamples(currentPixel, sampleStride);
        }
      }
      currentPixel.offset += edgeStride;
    }
  }

  /// Filters an edge with either the two-sample or four-sample kernel.
  void _filterNarrowEdge(
    _WebPBuffer pixels,
    int sampleStride,
    int edgeStride,
    int length,
    int threshold,
    int interiorThreshold,
    int highEdgeVarianceThreshold,
  ) {
    final _WebPBuffer currentPixel = _WebPBuffer.from(source: pixels);
    int remaining = length;
    while (remaining-- > 0) {
      if (_needsWideFilter(currentPixel, sampleStride, threshold, interiorThreshold)) {
        if (_hasHighEdgeVariance(currentPixel, sampleStride, highEdgeVarianceThreshold)) {
          _filterTwoSamples(currentPixel, sampleStride);
        } else {
          _filterFourSamples(currentPixel, sampleStride);
        }
      }
      currentPixel.offset += edgeStride;
    }
  }

  /// Filters four input samples and updates the two nearest to the edge.
  void _filterTwoSamples(_WebPBuffer pixels, int step) {
    final int previousOuter = pixels[-2 * step];
    final int previousInner = pixels[-step];
    final int nextInner = pixels[0];
    final int nextOuter = pixels[step];
    final int adjustment = 3 * (nextInner - previousInner) + _wideSignedClip[1020 + previousOuter - nextOuter];
    final int nextAdjustment = _narrowSignedClip[112 + _signedShiftRight(adjustment + 4, 3)];
    final int previousAdjustment = _narrowSignedClip[112 + _signedShiftRight(adjustment + 3, 3)];
    pixels[-step] = _unsignedClip[255 + previousInner + previousAdjustment];
    pixels[0] = _unsignedClip[255 + nextInner - nextAdjustment];
  }

  /// Filters four input samples and updates all four samples.
  void _filterFourSamples(_WebPBuffer pixels, int step) {
    final int previousOuter = pixels[-2 * step];
    final int previousInner = pixels[-step];
    final int nextInner = pixels[0];
    final int nextOuter = pixels[step];
    final int adjustment = 3 * (nextInner - previousInner);
    final int nextAdjustment = _narrowSignedClip[112 + _signedShiftRight(adjustment + 4, 3)];
    final int previousAdjustment = _narrowSignedClip[112 + _signedShiftRight(adjustment + 3, 3)];
    final int outerAdjustment = _signedShiftRight(nextAdjustment + 1, 1);
    pixels[-2 * step] = _unsignedClip[255 + previousOuter + outerAdjustment];
    pixels[-step] = _unsignedClip[255 + previousInner + previousAdjustment];
    pixels[0] = _unsignedClip[255 + nextInner - nextAdjustment];
    pixels[step] = _unsignedClip[255 + nextOuter - outerAdjustment];
  }

  /// Filters six input samples and updates all six samples.
  void _filterSixSamples(_WebPBuffer pixels, int step) {
    final int previousFar = pixels[-3 * step];
    final int previousOuter = pixels[-2 * step];
    final int previousInner = pixels[-step];
    final int nextInner = pixels[0];
    final int nextOuter = pixels[step];
    final int nextFar = pixels[2 * step];
    final int adjustment = _wideSignedClip[1020 + 3 * (nextInner - previousInner) + _wideSignedClip[1020 + previousOuter - nextOuter]];
    final int innerAdjustment = _signedShiftRight(27 * adjustment + 63, 7);
    final int outerAdjustment = _signedShiftRight(18 * adjustment + 63, 7);
    final int farAdjustment = _signedShiftRight(9 * adjustment + 63, 7);
    pixels[-3 * step] = _unsignedClip[255 + previousFar + farAdjustment];
    pixels[-2 * step] = _unsignedClip[255 + previousOuter + outerAdjustment];
    pixels[-step] = _unsignedClip[255 + previousInner + innerAdjustment];
    pixels[0] = _unsignedClip[255 + nextInner - innerAdjustment];
    pixels[step] = _unsignedClip[255 + nextOuter - outerAdjustment];
    pixels[2 * step] = _unsignedClip[255 + nextFar - farAdjustment];
  }

  /// Whether the edge exceeds the high-edge-variance threshold.
  bool _hasHighEdgeVariance(_WebPBuffer pixels, int step, int threshold) {
    final int previousOuter = pixels[-2 * step];
    final int previousInner = pixels[-step];
    final int nextInner = pixels[0];
    final int nextOuter = pixels[step];
    return _absolute[255 + previousOuter - previousInner] > threshold || _absolute[255 + nextOuter - nextInner] > threshold;
  }

  /// Whether a simple edge should be filtered.
  bool _needsFilter(_WebPBuffer pixels, int step, int threshold) {
    final int previousOuter = pixels[-2 * step];
    final int previousInner = pixels[-step];
    final int nextInner = pixels[0];
    final int nextOuter = pixels[step];
    return 2 * _absolute[255 + previousInner - nextInner] + _halfAbsolute[255 + previousOuter - nextOuter] <= threshold;
  }

  /// Whether an edge and its neighboring samples satisfy filter limits.
  bool _needsWideFilter(
    _WebPBuffer pixels,
    int step,
    int threshold,
    int interiorThreshold,
  ) {
    final int previousFar = pixels[-4 * step];
    final int previousMiddle = pixels[-3 * step];
    final int previousOuter = pixels[-2 * step];
    final int previousInner = pixels[-step];
    final int nextInner = pixels[0];
    final int nextOuter = pixels[step];
    final int nextMiddle = pixels[2 * step];
    final int nextFar = pixels[3 * step];
    if (2 * _absolute[255 + previousInner - nextInner] + _halfAbsolute[255 + previousOuter - nextOuter] > threshold) {
      return false;
    }

    return _absolute[255 + previousFar - previousMiddle] <= interiorThreshold &&
        _absolute[255 + previousMiddle - previousOuter] <= interiorThreshold &&
        _absolute[255 + previousOuter - previousInner] <= interiorThreshold &&
        _absolute[255 + nextFar - nextMiddle] <= interiorThreshold &&
        _absolute[255 + nextMiddle - nextOuter] <= interiorThreshold &&
        _absolute[255 + nextOuter - nextInner] <= interiorThreshold;
  }

  /// Applies the inverse transform to one 4 by 4 coefficient block.
  void inverseTransformBlock(
    _WebPBuffer source,
    _WebPBuffer destination,
  ) {
    final Int32List intermediate = Int32List(4 * 4);
    int sourceIndex = 0;
    int destinationIndex = 0;
    int intermediateIndex = 0;
    for (int column = 0; column < 4; ++column) {
      final int sum = source[sourceIndex] + source[sourceIndex + 8];
      final int difference = source[sourceIndex] - source[sourceIndex + 8];
      final int rotatedDifference = _multiplyFixedPoint(source[sourceIndex + 4], _transformCoefficient2) - _multiplyFixedPoint(source[sourceIndex + 12], _transformCoefficient1);
      final int rotatedSum = _multiplyFixedPoint(source[sourceIndex + 4], _transformCoefficient1) + _multiplyFixedPoint(source[sourceIndex + 12], _transformCoefficient2);
      intermediate[intermediateIndex++] = sum + rotatedSum;
      intermediate[intermediateIndex++] = difference + rotatedDifference;
      intermediate[intermediateIndex++] = difference - rotatedDifference;
      intermediate[intermediateIndex++] = sum - rotatedSum;
      sourceIndex++;
    }

    // Each pass is expanding the dynamic range by ~3.85 (upper bound).
    // The exact value is (2. + (_transformCoefficient1 + _transformCoefficient2) / 65536).
    // After the second pass, maximum interval is [-3794, 3794], assuming
    // an input in [-2048, 2047] interval. We then need to add a dst value
    // in the [0, 255] range.
    // In the worst case scenario, the input to clip_8b() can be as large as
    // [-60713, 60968].
    intermediateIndex = 0;
    for (int row = 0; row < 4; ++row) {
      final int directCurrent = intermediate[intermediateIndex] + 4;
      final int sum = directCurrent + intermediate[intermediateIndex + 8];
      final int difference = directCurrent - intermediate[intermediateIndex + 8];
      final int rotatedDifference =
          _multiplyFixedPoint(intermediate[intermediateIndex + 4], _transformCoefficient2) - _multiplyFixedPoint(intermediate[intermediateIndex + 12], _transformCoefficient1);
      final int rotatedSum = _multiplyFixedPoint(intermediate[intermediateIndex + 4], _transformCoefficient1) + _multiplyFixedPoint(intermediate[intermediateIndex + 12], _transformCoefficient2);
      _storeSample(destination, destinationIndex, 0, 0, sum + rotatedSum);
      _storeSample(destination, destinationIndex, 1, 0, difference + rotatedDifference);
      _storeSample(destination, destinationIndex, 2, 0, difference - rotatedDifference);
      _storeSample(destination, destinationIndex, 3, 0, sum - rotatedSum);
      intermediateIndex++;
      destinationIndex += _Vp8Decoder.reconstructionStride;
    }
  }

  /// Applies the inverse transform to one or two adjacent luma blocks.
  void inverseTransformLumaBlocks(
    _WebPBuffer source,
    _WebPBuffer destination,
    bool transformSecondBlock,
  ) {
    inverseTransformBlock(source, destination);
    if (transformSecondBlock) {
      inverseTransformBlock(
        _WebPBuffer.from(source: source, offset: 16),
        _WebPBuffer.from(source: destination, offset: 4),
      );
    }
  }

  /// Applies the inverse transform to a group of four chroma blocks.
  void inverseTransformChromaBlocks(
    _WebPBuffer source,
    _WebPBuffer destination,
  ) {
    inverseTransformLumaBlocks(source, destination, true);
    inverseTransformLumaBlocks(
      _WebPBuffer.from(source: source, offset: 2 * 16),
      _WebPBuffer.from(source: destination, offset: 4 * _Vp8Decoder.reconstructionStride),
      true,
    );
  }

  /// Applies a direct-current-only inverse transform to one block.
  void inverseTransformDirectCurrentBlock(
    _WebPBuffer source,
    _WebPBuffer destination,
  ) {
    final int directCurrent = source[0] + 4;
    for (int y = 0; y < 4; ++y) {
      for (int x = 0; x < 4; ++x) {
        _storeSample(destination, 0, x, y, directCurrent);
      }
    }
  }

  /// Applies direct-current-only inverse transforms to nonzero chroma blocks.
  void inverseTransformChromaDirectCurrent(
    _WebPBuffer source,
    _WebPBuffer destination,
  ) {
    if (source[0 * 16] != 0) {
      inverseTransformDirectCurrentBlock(source, destination);
    }
    if (source[1 * 16] != 0) {
      inverseTransformDirectCurrentBlock(
        _WebPBuffer.from(source: source, offset: 1 * 16),
        _WebPBuffer.from(source: destination, offset: 4),
      );
    }
    if (source[2 * 16] != 0) {
      inverseTransformDirectCurrentBlock(
        _WebPBuffer.from(source: source, offset: 2 * 16),
        _WebPBuffer.from(source: destination, offset: 4 * _Vp8Decoder.reconstructionStride),
      );
    }
    if (source[3 * 16] != 0) {
      inverseTransformDirectCurrentBlock(
        _WebPBuffer.from(source: source, offset: 3 * 16),
        _WebPBuffer.from(source: destination, offset: 4 * _Vp8Decoder.reconstructionStride + 4),
      );
    }
  }

  /// Applies the optimized inverse transform for three nonzero coefficients.
  void inverseTransformSparseBlock(
    _WebPBuffer source,
    _WebPBuffer destination,
  ) {
    final int directCurrent = source[0] + 4;
    final int verticalDifference = _multiplyFixedPoint(source[4], _transformCoefficient2);
    final int verticalSum = _multiplyFixedPoint(source[4], _transformCoefficient1);
    final int horizontalDifference = _multiplyFixedPoint(source[1], _transformCoefficient2);
    final int horizontalSum = _multiplyFixedPoint(source[1], _transformCoefficient1);
    _storeFourSamples(destination, 0, directCurrent + verticalSum, horizontalSum, horizontalDifference);
    _storeFourSamples(destination, 1, directCurrent + verticalDifference, horizontalSum, horizontalDifference);
    _storeFourSamples(destination, 2, directCurrent - verticalDifference, horizontalSum, horizontalDifference);
    _storeFourSamples(destination, 3, directCurrent - verticalSum, horizontalSum, horizontalDifference);
  }

  /// Returns a rounded one-two-one weighted average.
  static int _weightedAverage(int before, int center, int after) => _signedShiftRight(before + 2 * center + after + 2, 2);

  /// Returns the rounded average of two samples.
  static int _average(int first, int second) => _signedShiftRight(first + second + 1, 1);

  /// Predicts a 4 by 4 block from vertically adjacent samples.
  static void _predictVertical4(_WebPBuffer destination) {
    const int top = -_Vp8Decoder.reconstructionStride;
    final List<int> values = <int>[
      _weightedAverage(
        destination[top - 1],
        destination[top],
        destination[top + 1],
      ),
      _weightedAverage(
        destination[top],
        destination[top + 1],
        destination[top + 2],
      ),
      _weightedAverage(
        destination[top + 1],
        destination[top + 2],
        destination[top + 3],
      ),
      _weightedAverage(
        destination[top + 2],
        destination[top + 3],
        destination[top + 4],
      ),
    ];

    for (int row = 0; row < 4; ++row) {
      destination.memcpy(row * _Vp8Decoder.reconstructionStride, 4, values);
    }
  }

  /// Predicts a 4 by 4 block from horizontally adjacent samples.
  static void _predictHorizontal4(_WebPBuffer destination) {
    final int topLeft = destination[-1 - _Vp8Decoder.reconstructionStride];
    final int row0 = destination[-1];
    final int row1 = destination[-1 + _Vp8Decoder.reconstructionStride];
    final int row2 = destination[-1 + 2 * _Vp8Decoder.reconstructionStride];
    final int row3 = destination[-1 + 3 * _Vp8Decoder.reconstructionStride];

    final _WebPBuffer currentRow = _WebPBuffer.from(source: destination);

    currentRow.toUint32List()[0] = 0x01010101 * _weightedAverage(topLeft, row0, row1);
    currentRow.offset += _Vp8Decoder.reconstructionStride;
    currentRow.toUint32List()[0] = 0x01010101 * _weightedAverage(row0, row1, row2);
    currentRow.offset += _Vp8Decoder.reconstructionStride;
    currentRow.toUint32List()[0] = 0x01010101 * _weightedAverage(row1, row2, row3);
    currentRow.offset += _Vp8Decoder.reconstructionStride;
    currentRow.toUint32List()[0] = 0x01010101 * _weightedAverage(row2, row3, row3);
  }

  /// Predicts a 4 by 4 block from its neighboring direct-current value.
  static void _predictDirectCurrent4(_WebPBuffer destination) {
    int directCurrent = 4;
    for (int index = 0; index < 4; ++index) {
      directCurrent += destination[index - _Vp8Decoder.reconstructionStride] + destination[-1 + index * _Vp8Decoder.reconstructionStride];
    }
    directCurrent >>= 3;
    for (int row = 0; row < 4; ++row) {
      destination.memset(row * _Vp8Decoder.reconstructionStride, 4, directCurrent);
    }
  }

  /// Predicts a square block using VP8 true-motion prediction.
  static void _predictTrueMotion(_WebPBuffer destination, int size) {
    int destinationIndex = 0;
    const int top = -_Vp8Decoder.reconstructionStride;
    final int clipOffset = 255 - destination[top - 1];

    for (int y = 0; y < size; ++y) {
      final int rowClipOffset = clipOffset + destination[destinationIndex - 1];
      for (int x = 0; x < size; ++x) {
        destination[destinationIndex + x] = _unsignedClip[rowClipOffset + destination[top + x]];
      }

      destinationIndex += _Vp8Decoder.reconstructionStride;
    }
  }

  /// Predicts a 4 by 4 luma block using true-motion prediction.
  static void _predictTrueMotion4(_WebPBuffer destination) {
    _predictTrueMotion(destination, 4);
  }

  /// Predicts an 8 by 8 chroma block using true-motion prediction.
  static void _predictTrueMotionChroma(_WebPBuffer destination) {
    _predictTrueMotion(destination, 8);
  }

  /// Predicts a 16 by 16 luma block using true-motion prediction.
  static void _predictTrueMotionLuma(_WebPBuffer destination) {
    _predictTrueMotion(destination, 16);
  }

  /// Returns the offset for a pixel in the VP8 reconstruction buffer.
  static int _pixelOffset(int x, int y) => x + y * _Vp8Decoder.reconstructionStride;

  /// Predicts a 4 by 4 block diagonally down and to the right.
  static void _predictDownRight4(_WebPBuffer destination) {
    final int left0 = destination[-1];
    final int left1 = destination[-1 + _Vp8Decoder.reconstructionStride];
    final int left2 = destination[-1 + 2 * _Vp8Decoder.reconstructionStride];
    final int left3 = destination[-1 + 3 * _Vp8Decoder.reconstructionStride];
    final int topLeft = destination[-1 - _Vp8Decoder.reconstructionStride];
    final int top0 = destination[-_Vp8Decoder.reconstructionStride];
    final int top1 = destination[1 - _Vp8Decoder.reconstructionStride];
    final int top2 = destination[2 - _Vp8Decoder.reconstructionStride];
    final int top3 = destination[3 - _Vp8Decoder.reconstructionStride];

    destination[_pixelOffset(0, 3)] = _weightedAverage(left1, left2, left3);
    destination[_pixelOffset(0, 2)] = destination[_pixelOffset(1, 3)] = _weightedAverage(left0, left1, left2);
    destination[_pixelOffset(0, 1)] = destination[_pixelOffset(1, 2)] = destination[_pixelOffset(2, 3)] = _weightedAverage(topLeft, left0, left1);
    destination[_pixelOffset(0, 0)] = destination[_pixelOffset(1, 1)] = destination[_pixelOffset(2, 2)] = destination[_pixelOffset(3, 3)] = _weightedAverage(top0, topLeft, left0);
    destination[_pixelOffset(1, 0)] = destination[_pixelOffset(2, 1)] = destination[_pixelOffset(3, 2)] = _weightedAverage(top1, top0, topLeft);
    destination[_pixelOffset(2, 0)] = destination[_pixelOffset(3, 1)] = _weightedAverage(top2, top1, top0);
    destination[_pixelOffset(3, 0)] = _weightedAverage(top3, top2, top1);
  }

  /// Predicts a 4 by 4 block diagonally down and to the left.
  static void _predictDownLeft4(_WebPBuffer destination) {
    final int top0 = destination[-_Vp8Decoder.reconstructionStride];
    final int top1 = destination[1 - _Vp8Decoder.reconstructionStride];
    final int top2 = destination[2 - _Vp8Decoder.reconstructionStride];
    final int top3 = destination[3 - _Vp8Decoder.reconstructionStride];
    final int top4 = destination[4 - _Vp8Decoder.reconstructionStride];
    final int top5 = destination[5 - _Vp8Decoder.reconstructionStride];
    final int top6 = destination[6 - _Vp8Decoder.reconstructionStride];
    final int top7 = destination[7 - _Vp8Decoder.reconstructionStride];
    destination[_pixelOffset(0, 0)] = _weightedAverage(top0, top1, top2);
    destination[_pixelOffset(1, 0)] = destination[_pixelOffset(0, 1)] = _weightedAverage(top1, top2, top3);
    destination[_pixelOffset(2, 0)] = destination[_pixelOffset(1, 1)] = destination[_pixelOffset(0, 2)] = _weightedAverage(top2, top3, top4);
    destination[_pixelOffset(3, 0)] = destination[_pixelOffset(2, 1)] = destination[_pixelOffset(1, 2)] = destination[_pixelOffset(0, 3)] = _weightedAverage(top3, top4, top5);
    destination[_pixelOffset(3, 1)] = destination[_pixelOffset(2, 2)] = destination[_pixelOffset(1, 3)] = _weightedAverage(top4, top5, top6);
    destination[_pixelOffset(3, 2)] = destination[_pixelOffset(2, 3)] = _weightedAverage(top5, top6, top7);
    destination[_pixelOffset(3, 3)] = _weightedAverage(top6, top7, top7);
  }

  /// Predicts a 4 by 4 block primarily vertically and to the right.
  static void _predictVerticalRight4(_WebPBuffer destination) {
    final int left0 = destination[-1];
    final int left1 = destination[-1 + _Vp8Decoder.reconstructionStride];
    final int left2 = destination[-1 + 2 * _Vp8Decoder.reconstructionStride];
    final int topLeft = destination[-1 - _Vp8Decoder.reconstructionStride];
    final int top0 = destination[-_Vp8Decoder.reconstructionStride];
    final int top1 = destination[1 - _Vp8Decoder.reconstructionStride];
    final int top2 = destination[2 - _Vp8Decoder.reconstructionStride];
    final int top3 = destination[3 - _Vp8Decoder.reconstructionStride];
    destination[_pixelOffset(0, 0)] = destination[_pixelOffset(1, 2)] = _average(topLeft, top0);
    destination[_pixelOffset(1, 0)] = destination[_pixelOffset(2, 2)] = _average(top0, top1);
    destination[_pixelOffset(2, 0)] = destination[_pixelOffset(3, 2)] = _average(top1, top2);
    destination[_pixelOffset(3, 0)] = _average(top2, top3);

    destination[_pixelOffset(0, 3)] = _weightedAverage(left2, left1, left0);
    destination[_pixelOffset(0, 2)] = _weightedAverage(left1, left0, topLeft);
    destination[_pixelOffset(0, 1)] = destination[_pixelOffset(1, 3)] = _weightedAverage(left0, topLeft, top0);
    destination[_pixelOffset(1, 1)] = destination[_pixelOffset(2, 3)] = _weightedAverage(topLeft, top0, top1);
    destination[_pixelOffset(2, 1)] = destination[_pixelOffset(3, 3)] = _weightedAverage(top0, top1, top2);
    destination[_pixelOffset(3, 1)] = _weightedAverage(top1, top2, top3);
  }

  /// Predicts a 4 by 4 block primarily vertically and to the left.
  static void _predictVerticalLeft4(_WebPBuffer destination) {
    final int top0 = destination[-_Vp8Decoder.reconstructionStride];
    final int top1 = destination[1 - _Vp8Decoder.reconstructionStride];
    final int top2 = destination[2 - _Vp8Decoder.reconstructionStride];
    final int top3 = destination[3 - _Vp8Decoder.reconstructionStride];
    final int top4 = destination[4 - _Vp8Decoder.reconstructionStride];
    final int top5 = destination[5 - _Vp8Decoder.reconstructionStride];
    final int top6 = destination[6 - _Vp8Decoder.reconstructionStride];
    final int top7 = destination[7 - _Vp8Decoder.reconstructionStride];
    destination[_pixelOffset(0, 0)] = _average(top0, top1);
    destination[_pixelOffset(1, 0)] = destination[_pixelOffset(0, 2)] = _average(top1, top2);
    destination[_pixelOffset(2, 0)] = destination[_pixelOffset(1, 2)] = _average(top2, top3);
    destination[_pixelOffset(3, 0)] = destination[_pixelOffset(2, 2)] = _average(top3, top4);

    destination[_pixelOffset(0, 1)] = _weightedAverage(top0, top1, top2);
    destination[_pixelOffset(1, 1)] = destination[_pixelOffset(0, 3)] = _weightedAverage(top1, top2, top3);
    destination[_pixelOffset(2, 1)] = destination[_pixelOffset(1, 3)] = _weightedAverage(top2, top3, top4);
    destination[_pixelOffset(3, 1)] = destination[_pixelOffset(2, 3)] = _weightedAverage(top3, top4, top5);
    destination[_pixelOffset(3, 2)] = _weightedAverage(top4, top5, top6);
    destination[_pixelOffset(3, 3)] = _weightedAverage(top5, top6, top7);
  }

  /// Predicts a 4 by 4 block primarily horizontally and upward.
  static void _predictHorizontalUp4(_WebPBuffer destination) {
    final int left0 = destination[-1];
    final int left1 = destination[-1 + _Vp8Decoder.reconstructionStride];
    final int left2 = destination[-1 + 2 * _Vp8Decoder.reconstructionStride];
    final int left3 = destination[-1 + 3 * _Vp8Decoder.reconstructionStride];
    destination[_pixelOffset(0, 0)] = _average(left0, left1);
    destination[_pixelOffset(2, 0)] = destination[_pixelOffset(0, 1)] = _average(left1, left2);
    destination[_pixelOffset(2, 1)] = destination[_pixelOffset(0, 2)] = _average(left2, left3);
    destination[_pixelOffset(1, 0)] = _weightedAverage(left0, left1, left2);
    destination[_pixelOffset(3, 0)] = destination[_pixelOffset(1, 1)] = _weightedAverage(left1, left2, left3);
    destination[_pixelOffset(3, 1)] = destination[_pixelOffset(1, 2)] = _weightedAverage(left2, left3, left3);
    destination[_pixelOffset(3, 2)] = destination[_pixelOffset(2, 2)] = destination[_pixelOffset(0, 3)] = destination[_pixelOffset(1, 3)] = destination[_pixelOffset(2, 3)] =
        destination[_pixelOffset(3, 3)] = left3;
  }

  /// Predicts a 4 by 4 block primarily horizontally and downward.
  static void _predictHorizontalDown4(_WebPBuffer destination) {
    final int left0 = destination[-1];
    final int left1 = destination[-1 + _Vp8Decoder.reconstructionStride];
    final int left2 = destination[-1 + 2 * _Vp8Decoder.reconstructionStride];
    final int left3 = destination[-1 + 3 * _Vp8Decoder.reconstructionStride];
    final int topLeft = destination[-1 - _Vp8Decoder.reconstructionStride];
    final int top0 = destination[-_Vp8Decoder.reconstructionStride];
    final int top1 = destination[1 - _Vp8Decoder.reconstructionStride];
    final int top2 = destination[2 - _Vp8Decoder.reconstructionStride];

    destination[_pixelOffset(0, 0)] = destination[_pixelOffset(2, 1)] = _average(left0, topLeft);
    destination[_pixelOffset(0, 1)] = destination[_pixelOffset(2, 2)] = _average(left1, left0);
    destination[_pixelOffset(0, 2)] = destination[_pixelOffset(2, 3)] = _average(left2, left1);
    destination[_pixelOffset(0, 3)] = _average(left3, left2);

    destination[_pixelOffset(3, 0)] = _weightedAverage(top0, top1, top2);
    destination[_pixelOffset(2, 0)] = _weightedAverage(topLeft, top0, top1);
    destination[_pixelOffset(1, 0)] = destination[_pixelOffset(3, 1)] = _weightedAverage(left0, topLeft, top0);
    destination[_pixelOffset(1, 1)] = destination[_pixelOffset(3, 2)] = _weightedAverage(left1, left0, topLeft);
    destination[_pixelOffset(1, 2)] = destination[_pixelOffset(3, 3)] = _weightedAverage(left2, left1, left0);
    destination[_pixelOffset(1, 3)] = _weightedAverage(left3, left2, left1);
  }

  /// Predicts a 16 by 16 luma block from its top row.
  static void _predictVerticalLuma16(_WebPBuffer destination) {
    for (int row = 0; row < 16; ++row) {
      destination.memcpy(
        row * _Vp8Decoder.reconstructionStride,
        16,
        destination,
        -_Vp8Decoder.reconstructionStride,
      );
    }
  }

  /// Predicts a 16 by 16 luma block from its left column.
  static void _predictHorizontalLuma16(_WebPBuffer destination) {
    int destinationIndex = 0;
    for (int row = 16; row > 0; --row) {
      destination.memset(
        destinationIndex,
        16,
        destination[destinationIndex - 1],
      );
      destinationIndex += _Vp8Decoder.reconstructionStride;
    }
  }

  /// Fills a 16 by 16 luma block with one sample value.
  static void _fillLumaBlock(int value, _WebPBuffer destination) {
    for (int row = 0; row < 16; ++row) {
      destination.memset(row * _Vp8Decoder.reconstructionStride, 16, value);
    }
  }

  /// Predicts luma from the direct-current value of all neighbors.
  static void _predictDirectCurrentLuma(_WebPBuffer destination) {
    int directCurrent = 16;
    for (int index = 0; index < 16; ++index) {
      directCurrent += destination[-1 + index * _Vp8Decoder.reconstructionStride] + destination[index - _Vp8Decoder.reconstructionStride];
    }
    _fillLumaBlock(directCurrent >> 5, destination);
  }

  /// Predicts luma from left samples when top samples are unavailable.
    static void _predictDirectCurrentLumaWithoutTop(_WebPBuffer destination) {
    int directCurrent = 8;
    for (int row = 0; row < 16; ++row) {
      directCurrent += destination[-1 + row * _Vp8Decoder.reconstructionStride];
    }
    _fillLumaBlock(directCurrent >> 4, destination);
  }

  /// Predicts luma from top samples when left samples are unavailable.
    static void _predictDirectCurrentLumaWithoutLeft(_WebPBuffer destination) {
    int directCurrent = 8;
    for (int column = 0; column < 16; ++column) {
      directCurrent += destination[column - _Vp8Decoder.reconstructionStride];
    }
    _fillLumaBlock(directCurrent >> 4, destination);
  }

  /// Predicts neutral luma when no neighboring samples are available.
    static void _predictDirectCurrentLumaWithoutNeighbors(
    _WebPBuffer destination,
  ) {
    _fillLumaBlock(0x80, destination);
  }

  /// Predicts an 8 by 8 chroma block from its top row.
    static void _predictVerticalChroma(_WebPBuffer destination) {
    for (int row = 0; row < 8; ++row) {
      destination.memcpy(
        row * _Vp8Decoder.reconstructionStride,
        8,
        destination,
        -_Vp8Decoder.reconstructionStride,
      );
    }
  }

  /// Predicts an 8 by 8 chroma block from its left column.
    static void _predictHorizontalChroma(_WebPBuffer destination) {
    int destinationIndex = 0;
    for (int row = 0; row < 8; ++row) {
      destination.memset(
        destinationIndex,
        8,
        destination[destinationIndex - 1],
      );
      destinationIndex += _Vp8Decoder.reconstructionStride;
    }
  }

  /// Fills an 8 by 8 chroma block with one sample value.
    static void _fillChromaBlock(int value, _WebPBuffer destination) {
    for (int row = 0; row < 8; ++row) {
      destination.memset(row * _Vp8Decoder.reconstructionStride, 8, value);
    }
  }

  /// Predicts chroma from the direct-current value of all neighbors.
    static void _predictDirectCurrentChroma(_WebPBuffer destination) {
    int directCurrent = 8;
    for (int index = 0; index < 8; ++index) {
      directCurrent += destination[index - _Vp8Decoder.reconstructionStride] + destination[-1 + index * _Vp8Decoder.reconstructionStride];
    }
    _fillChromaBlock(directCurrent >> 4, destination);
  }

  /// Predicts chroma from top samples when left samples are unavailable.
    static void _predictDirectCurrentChromaWithoutLeft(
    _WebPBuffer destination,
  ) {
    int directCurrent = 4;
    for (int column = 0; column < 8; ++column) {
      directCurrent += destination[column - _Vp8Decoder.reconstructionStride];
    }
    _fillChromaBlock(directCurrent >> 3, destination);
  }

  /// Predicts chroma from left samples when top samples are unavailable.
    static void _predictDirectCurrentChromaWithoutTop(
    _WebPBuffer destination,
  ) {
    int directCurrent = 4;
    for (int row = 0; row < 8; ++row) {
      directCurrent += destination[-1 + row * _Vp8Decoder.reconstructionStride];
    }
    _fillChromaBlock(directCurrent >> 3, destination);
  }

  /// Predicts neutral chroma when no neighboring samples are available.
    static void _predictDirectCurrentChromaWithoutNeighbors(
    _WebPBuffer destination,
  ) {
    _fillChromaBlock(0x80, destination);
  }

  /// Multiplies two fixed-point values and restores their original scale.
    static int _multiplyFixedPoint(int first, int second) {
    final int product = first * second;
    return _signedShiftRight(product, 16);
  }

  /// Adds a transformed value to one prediction sample and clips the result.
    static void _storeSample(
    _WebPBuffer destination,
    int destinationIndex,
    int x,
    int y,
    int value,
  ) {
    final int index = destinationIndex + x + y * _Vp8Decoder.reconstructionStride;
    destination[index] = _clampToByte(destination[index] + (value >> 3));
  }

  /// Stores one transformed row of four samples.
    static void _storeFourSamples(
    _WebPBuffer destination,
    int y,
    int directCurrent,
    int outerDifference,
    int innerDifference,
  ) {
    _storeSample(destination, 0, 0, y, directCurrent + outerDifference);
    _storeSample(destination, 0, 1, y, directCurrent + innerDifference);
    _storeSample(destination, 0, 2, y, directCurrent - innerDifference);
    _storeSample(destination, 0, 3, y, directCurrent - outerDifference);
  }

  /// Initializes the shared lookup tables once per isolate.
    static void _initTables() {
    if (!_tablesInitialized) {
      for (int value = -255; value <= 255; ++value) {
        _absolute[255 + value] = value < 0 ? -value : value;
        _halfAbsolute[255 + value] = _absolute[255 + value] >> 1;
      }
      for (int value = -1020; value <= 1020; ++value) {
        _wideSignedClip[1020 + value] = (value < -128)
            ? -128
            : (value > 127)
            ? 127
            : value;
      }
      for (int value = -112; value <= 112; ++value) {
        _narrowSignedClip[112 + value] = (value < -16)
            ? -16
            : (value > 15)
            ? 15
            : value;
      }
      for (int value = -255; value <= 255 + 255; ++value) {
        _unsignedClip[255 + value] = (value < 0)
            ? 0
            : (value > 255)
            ? 255
            : value;
      }
      _tablesInitialized = true;
    }
  }

  /// Clips [value] to the unsigned byte range.
    static int _clampToByte(int value) => ((value & -256) == 0)
      ? value
      : (value < 0)
      ? 0
      : 255;
}
