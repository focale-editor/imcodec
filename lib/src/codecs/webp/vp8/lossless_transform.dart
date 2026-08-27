part of '../../webp.dart';

/// Transform types defined by the VP8L bitstream.
enum _Vp8LosslessTransformType {
  /// Predicts pixels from reconstructed neighbors.
  predictor,

  /// Decorrelates red and blue from the green channel.
  crossColor,

  /// Stores red and blue as differences from green.
  subtractGreen,

  /// Replaces pixels with indexes into a color table.
  colorIndexing,
}

/// Reverses one transform applied to a VP8L pixel stream.
final class _Vp8LosslessTransform {
  /// Predictor functions indexed by their encoded mode.
  static final List<int Function(Uint32List pixels, int left, int top)> _predictors = [
    _predictor0,
    _predictor1,
    _predictor2,
    _predictor3,
    _predictor4,
    _predictor5,
    _predictor6,
    _predictor7,
    _predictor8,
    _predictor9,
    _predictor10,
    _predictor11,
    _predictor12,
    _predictor13,
    _predictor0,
    _predictor0,
  ];

  /// Transform selected by the encoded stream.
  _Vp8LosslessTransformType type = _Vp8LosslessTransformType.predictor;

  /// Width of the transformed image in pixels.
  int width = 0;

  /// Height of the transformed image in pixels.
  int height = 0;

  /// Transform-specific image, predictor modes, or color table.
  Uint32List? data;

  /// Block-size exponent or palette packing exponent.
  int bits = 0;

  /// Creates an empty transform description.
  _Vp8LosslessTransform();

  /// Reverses this transform for rows from [rowStart] through [rowEnd].
  void inverseTransform(int rowStart, int rowEnd, Uint32List inData, int rowsIn, Uint32List outData, int rowsOut) {
    final int transformWidth = width;

    switch (type) {
      case _Vp8LosslessTransformType.subtractGreen:
        addGreenToBlueAndRed(outData, rowsOut, rowsOut + (rowEnd - rowStart) * transformWidth);
        break;
      case _Vp8LosslessTransformType.predictor:
        predictorInverseTransform(rowStart, rowEnd, outData, rowsOut);
        if (rowEnd != height) {
          // The last predicted row in this iteration will be the top-pred row
          // for the first row in next iteration.
          final int start = rowsOut - transformWidth;
          final int end = start + transformWidth;
          final int offset = rowsOut + (rowEnd - rowStart - 1) * transformWidth;
          outData.setRange(start, end, inData, offset);
        }
        break;
      case _Vp8LosslessTransformType.crossColor:
        colorSpaceInverseTransform(rowStart, rowEnd, outData, rowsOut);
        break;
      case _Vp8LosslessTransformType.colorIndexing:
        if (rowsIn == rowsOut && bits > 0) {
          // Move packed pixels to the end of unpacked region, so that unpacking
          // can occur seamlessly.
          // Also, note that this is the only transform that applies on
          // the effective width of VP8LSubSampleSize(xsize_, bits_). All other
          // transforms work on effective width of xsize_.
          final int outStride = (rowEnd - rowStart) * transformWidth;
          final int inStride = (rowEnd - rowStart) * _Vp8LosslessDecoder._subsampledSize(transformWidth, bits);

          final int src = rowsOut + outStride - inStride;
          outData.setRange(src, src + inStride, inData, rowsOut);

          colorIndexInverseTransform(rowStart, rowEnd, inData, src, outData, rowsOut);
        } else {
          colorIndexInverseTransform(rowStart, rowEnd, inData, rowsIn, outData, rowsOut);
        }
        break;
    }
  }

  /// Expands palette indexes into alpha values for the selected row range.
  void colorIndexInverseTransformAlpha(int yStart, int yEnd, _WebPBuffer src, _WebPBuffer dst) {
    final int bitsPerPixel = 8 >> bits;
    final int width = this.width;
    final Uint32List? colorMap = data;
    if (bitsPerPixel < 8) {
      final int pixelsPerByte = 1 << bits;
      final int countMask = pixelsPerByte - 1;
      final int bitMask = (1 << bitsPerPixel) - 1;
      for (var y = yStart; y < yEnd; ++y) {
        var packedPixels = 0;
        for (var x = 0; x < width; ++x) {
          // We need to load fresh 'packed_pixels' once every
          // 'pixels_per_byte' increments of x. Fortunately, pixels_per_byte
          // is a power of 2, so can just use a mask for that, instead of
          // decrementing a counter.
          if ((x & countMask) == 0) {
            packedPixels = _getAlphaIndex(src[0]);
            src.offset++;
          }
          final int p = _getAlphaValue(colorMap![packedPixels & bitMask]);
          dst[0] = p;
          dst.offset++;
          packedPixels >>= bitsPerPixel;
        }
      }
    } else {
      for (var y = yStart; y < yEnd; ++y) {
        for (var x = 0; x < width; ++x) {
          final int index = _getAlphaIndex(src[0]);
          src.offset++;
          dst[0] = _getAlphaValue(colorMap![index]);
          dst.offset++;
        }
      }
    }
  }

  /// Expands palette indexes into packed colors for the selected row range.
  void colorIndexInverseTransform(int yStart, int yEnd, Uint32List inData, int src, Uint32List outData, int dst) {
    final int bitsPerPixel = 8 >> bits;
    final int width = this.width;
    final Uint32List? colorMap = data;
    if (bitsPerPixel < 8) {
      final int pixelsPerByte = 1 << bits;
      final int countMask = pixelsPerByte - 1;
      final int bitMask = (1 << bitsPerPixel) - 1;
      for (var y = yStart; y < yEnd; ++y) {
        var packedPixels = 0;
        for (var x = 0; x < width; ++x) {
          // We need to load fresh 'packedPixels' once every
          // 'pixels_per_byte' increments of x. Fortunately, pixels_per_byte
          // is a power of 2, so can just use a mask for that, instead of
          // decrementing a counter.
          if ((x & countMask) == 0) {
            packedPixels = _getARGBIndex(inData[src++]);
          }
          outData[dst++] = _getARGBValue(colorMap![packedPixels & bitMask]);
          packedPixels >>= bitsPerPixel;
        }
      }
    } else {
      for (var y = yStart; y < yEnd; ++y) {
        for (var x = 0; x < width; ++x) {
          outData[dst++] = _getARGBValue(colorMap![_getARGBIndex(inData[src++])]);
        }
      }
    }
  }

  /// Reverses cross-channel color decorrelation for selected rows.
  void colorSpaceInverseTransform(int yStart, int yEnd, Uint32List outData, int data) {
    final int width = this.width;
    final int mask = (1 << bits) - 1;
    final int tilesPerRow = _Vp8LosslessDecoder._subsampledSize(width, bits);
    int y = yStart;
    int outputOffset = data;
    int predRow = (y >> bits) * tilesPerRow; //this.data +

    while (y < yEnd) {
      var pred = predRow; // this.data+
      final m = _Vp8LosslessMultipliers();

      for (var x = 0; x < width; ++x) {
        if ((x & mask) == 0) {
          m.colorCode = this.data![pred++];
        }

        outData[outputOffset + x] = m.transformColor(outData[outputOffset + x]);
      }

      outputOffset += width;
      ++y;

      if ((y & mask) == 0) {
        predRow += tilesPerRow;
      }
    }
  }

  /// Reconstructs selected rows from their spatial predictors.
  void predictorInverseTransform(int yStart, int yEnd, Uint32List outData, int data) {
    final int width = this.width;
    int y = yStart;
    int outputOffset = data;
    if (y == 0) {
      // First Row follows the L (mode=1) mode.
      final int pred0 = _predictor0(outData, outData[outputOffset - 1], 0);
      _addPixelsEq(outData, outputOffset, pred0);
      for (var x = 1; x < width; ++x) {
        final int pred1 = _predictor1(outData, outData[outputOffset + x - 1], 0);
        _addPixelsEq(outData, outputOffset + x, pred1);
      }
      outputOffset += width;
      ++y;
    }

    final int mask = (1 << bits) - 1;
    final int tilesPerRow = _Vp8LosslessDecoder._subsampledSize(width, bits);
    int predModeBase = (y >> bits) * tilesPerRow; //this.data +

    while (y < yEnd) {
      final int pred2 = _predictor2(outData, outData[outputOffset - 1], outputOffset - width);
      var predModeSrc = predModeBase; //this.data +

      // First pixel follows the T (mode=2) mode.
      _addPixelsEq(outData, outputOffset, pred2);

      // .. the rest:
      final int k = (this.data![predModeSrc++] >> 8) & 0xf;

      int Function(Uint32List pixels, int left, int top) predFunc = _predictors[k];
      for (var x = 1; x < width; ++x) {
        if ((x & mask) == 0) {
          // start of tile. Read predictor function.
          final int k = ((this.data![predModeSrc++]) >> 8) & 0xf;
          predFunc = _predictors[k];
        }
        final int d = outData[outputOffset + x - 1];
        final int pred = predFunc(outData, d, outputOffset + x - width);
        _addPixelsEq(outData, outputOffset + x, pred);
      }

      outputOffset += width;
      ++y;

      if ((y & mask) == 0) {
        // Use the same mask, since tiles are squares.
        predModeBase += tilesPerRow;
      }
    }
  }

  /// Adds green back to red and blue for pixels in the selected range.
  void addGreenToBlueAndRed(Uint32List pixels, int data, int dataEnd) {
    int pixelIndex = data;
    while (pixelIndex < dataEnd) {
      final int argb = pixels[pixelIndex];
      final int green = (argb >> 8) & 0xff;
      int redBlue = argb & 0x00ff00ff;
      redBlue += (green << 16) | green;
      redBlue &= 0x00ff00ff;
      pixels[pixelIndex++] = (argb & 0xff00ff00) | redBlue;
    }
  }

  /// Extracts a palette index from a packed VP8L pixel.
  static int _getARGBIndex(int idx) => (idx >> 8) & 0xff;

  /// Extracts a palette index from one packed alpha byte.
  static int _getAlphaIndex(int idx) => idx;

  /// Returns a packed palette color unchanged.
  static int _getARGBValue(int val) => val;

  /// Extracts alpha from a packed palette color.
  static int _getAlphaValue(int val) => (val >> 8) & 0xff;

  /// Adds packed pixel components independently modulo 256.
  static void _addPixelsEq(Uint32List pixels, int a, int b) {
    final int pa = pixels[a];
    final int alphaAndGreen = (pa & 0xff00ff00) + (b & 0xff00ff00);
    final int redAndBlue = (pa & 0x00ff00ff) + (b & 0x00ff00ff);
    pixels[a] = (alphaAndGreen & 0xff00ff00) | (redAndBlue & 0x00ff00ff);
  }

  /// Averages two packed colors component by component.
  static int _average2(int a0, int a1) => (((a0 ^ a1) & 0xfefefefe) >> 1) + (a0 & a1);

  /// Averages three packed colors component by component.
  static int _average3(int a0, int a1, int a2) => _average2(_average2(a0, a2), a1);

  /// Averages four packed colors component by component.
  static int _average4(int a0, int a1, int a2, int a3) => _average2(_average2(a0, a1), _average2(a2, a3));

  /// Clamps [a] to an unsigned byte.
  static int _clip255(int a) {
    if (a < 0) {
      return 0;
    }
    if (a > 255) {
      return 255;
    }
    return a;
  }

  /// Predicts one component using a full clamped gradient.
  static int _addSubtractComponentFull(int a, int b, int c) => _clip255(a + b - c);

  /// Applies a full clamped gradient to every packed component.
  static int _clampedAddSubtractFull(int c0, int c1, int c2) {
    final int a = _addSubtractComponentFull(c0 >> 24, c1 >> 24, c2 >> 24);
    final int r = _addSubtractComponentFull((c0 >> 16) & 0xff, (c1 >> 16) & 0xff, (c2 >> 16) & 0xff);
    final int g = _addSubtractComponentFull((c0 >> 8) & 0xff, (c1 >> 8) & 0xff, (c2 >> 8) & 0xff);
    final int b = _addSubtractComponentFull(c0 & 0xff, c1 & 0xff, c2 & 0xff);
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  /// Predicts one component using a half-strength clamped gradient.
  static int _addSubtractComponentHalf(int a, int b) => _clip255(a + (a - b) ~/ 2);

  /// Applies a half-strength clamped gradient to every packed component.
  static int _clampedAddSubtractHalf(int c0, int c1, int c2) {
    final int avg = _average2(c0, c1);
    final int a = _addSubtractComponentHalf(avg >> 24, c2 >> 24);
    final int r = _addSubtractComponentHalf((avg >> 16) & 0xff, (c2 >> 16) & 0xff);
    final int g = _addSubtractComponentHalf((avg >> 8) & 0xff, (c2 >> 8) & 0xff);
    final int b = _addSubtractComponentHalf((avg >> 0) & 0xff, (c2 >> 0) & 0xff);
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  /// Compares the distance of [a] and [b] from [c].
  static int _sub3(int a, int b, int c) {
    final int pb = b - c;
    final int pa = a - c;
    return pb.abs() - pa.abs();
  }

  /// Chooses the packed color closest to the upper-left neighbor.
  static int _select(int a, int b, int c) {
    final int paMinusPb =
        _sub3(a >> 24, b >> 24, c >> 24) + _sub3((a >> 16) & 0xff, (b >> 16) & 0xff, (c >> 16) & 0xff) + _sub3((a >> 8) & 0xff, (b >> 8) & 0xff, (c >> 8) & 0xff) + _sub3(a & 0xff, b & 0xff, c & 0xff);
    return (paMinusPb <= 0) ? a : b;
  }

  /// Returns opaque black for predictor mode zero.
  static int _predictor0(Uint32List pixels, int left, int top) => _Vp8LosslessDecoder.opaqueBlack;

  /// Returns the left neighbor.
  static int _predictor1(Uint32List pixels, int left, int top) => left;

  /// Returns the top neighbor.
  static int _predictor2(Uint32List pixels, int left, int top) => pixels[top];

  /// Returns the upper-right neighbor.
  static int _predictor3(Uint32List pixels, int left, int top) => pixels[top + 1];

  /// Returns the upper-left neighbor.
  static int _predictor4(Uint32List pixels, int left, int top) => pixels[top - 1];

  /// Averages the left, top, and upper-right neighbors.
  static int _predictor5(Uint32List pixels, int left, int top) => _average3(left, pixels[top], pixels[top + 1]);

  /// Averages the left and upper-left neighbors.
  static int _predictor6(Uint32List pixels, int left, int top) => _average2(left, pixels[top - 1]);

  /// Averages the left and top neighbors.
  static int _predictor7(Uint32List pixels, int left, int top) => _average2(left, pixels[top]);

  /// Averages the upper-left and top neighbors.
  static int _predictor8(Uint32List pixels, int left, int top) => _average2(pixels[top - 1], pixels[top]);

  /// Averages the top and upper-right neighbors.
    static int _predictor9(Uint32List pixels, int left, int top) => _average2(pixels[top], pixels[top + 1]);

  /// Averages all four adjacent reconstructed neighbors.
    static int _predictor10(Uint32List pixels, int left, int top) => _average4(left, pixels[top - 1], pixels[top], pixels[top + 1]);

  /// Selects between the top and left neighbors.
    static int _predictor11(Uint32List pixels, int left, int top) => _select(pixels[top], left, pixels[top - 1]);

  /// Applies the full clamped gradient predictor.
    static int _predictor12(Uint32List pixels, int left, int top) => _clampedAddSubtractFull(left, pixels[top], pixels[top - 1]);

  /// Applies the half-strength clamped gradient predictor.
    static int _predictor13(Uint32List pixels, int left, int top) => _clampedAddSubtractHalf(left, pixels[top], pixels[top - 1]);
}

/// Stores the three signed cross-channel multipliers of a VP8L tile.
final class _Vp8LosslessMultipliers {
  /// Multipliers stored as bytes so negative values wrap modulo 256.
    final Uint8List _values = Uint8List(3);

  /// Creates zeroed channel multipliers.
    _Vp8LosslessMultipliers();

  /// Multiplier applied from green to red.
    int get greenToRed => _values[0];

  /// Changes the multiplier applied from green to red.
    set greenToRed(int multiplier) => _values[0] = multiplier;

  /// Multiplier applied from green to blue.
    int get greenToBlue => _values[1];

  /// Changes the multiplier applied from green to blue.
    set greenToBlue(int multiplier) => _values[1] = multiplier;

  /// Multiplier applied from red to blue.
    int get redToBlue => _values[2];

  /// Changes the multiplier applied from red to blue.
    set redToBlue(int multiplier) => _values[2] = multiplier;

  /// Resets all channel multipliers to zero.
    void clear() {
    _values.fillRange(0, _values.length, 0);
  }

  /// Unpacks the three multipliers from [colorCode].
    set colorCode(int colorCode) {
    _values[0] = colorCode & 0xff;
    _values[1] = (colorCode >> 8) & 0xff;
    _values[2] = (colorCode >> 16) & 0xff;
  }

  /// Packs the three multipliers into a color-code word.
    int get colorCode => 0xff000000 | (_values[2] << 16) | (_values[1] << 8) | _values[0];

  /// Reverses cross-channel decorrelation for one packed [color].
    int transformColor(int color) {
    final int green = (color >> 8) & 0xff;
    int red = (color >> 16) & 0xff;
    int blue = color & 0xff;
    red = (red + _colorTransformDelta(greenToRed, green)) & 0xff;
    blue = (blue + _colorTransformDelta(greenToBlue, green) + _colorTransformDelta(redToBlue, red)) & 0xff;
    return (color & 0xff00ff00) | (red << 16) | blue;
  }

  /// Calculates one signed fixed-point cross-channel adjustment.
    int _colorTransformDelta(int multiplier, int color) {
    final int a = _unsignedByteToSigned(multiplier);
    final int b = _unsignedByteToSigned(color);
    return _signedInt32ToUnsigned(a * b) >> 5;
  }
}
