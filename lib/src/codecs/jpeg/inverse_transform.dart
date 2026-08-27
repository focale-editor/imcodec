part of '../jpeg.dart';

/// Lookup table that clamps inverse-transform samples to one byte.
final Uint8List _dctClip = _createDctClip();

/// Index corresponding to zero in [_dctClip].
const int _dctClipOffset = 256;

/// Number of entries reserved for the clipping lookup table.
const int _dctClipLength = 768;

/// Builds the sample-clipping lookup table used by the inverse transform.
Uint8List _createDctClip() {
  final result = Uint8List(_dctClipLength);
  int i;
  for (i = -256; i < 0; ++i) {
    result[_dctClipOffset + i] = 0;
  }
  for (i = 0; i < 256; ++i) {
    result[_dctClipOffset + i] = i;
  }
  for (i = 256; i < 512; ++i) {
    result[_dctClipOffset + i] = 255;
  }
  return result;
}

/// Dequantizes one coefficient block and applies the inverse transform.
/// This is an integer implementation of the Loeffler-Ligtenberg-Moschytz
/// inverse discrete cosine transform.
void _inverseTransformBlock(Int16List quantizationTable, Int32List coefBlock, Uint8List dataOut, Int32List dataIn) {
  final p = dataIn;

  // IDCT constants (20.12 fixed point format)
  const cos1 = 4017; // cos(pi/16)*4096
  const sin1 = 799; // sin(pi/16)*4096
  const cos3 = 3406; // cos(3*pi/16)*4096
  const sin3 = 2276; // sin(3*pi/16)*4096
  const cos6 = 1567; // cos(6*pi/16)*4096
  const sin6 = 3784; // sin(6*pi/16)*4096
  const sqrt2 = 5793; // sqrt(2)*4096
  const sqrt102 = 2896; // sqrt(2) / 2

  // de-quantize
  for (var i = 0; i < 64; i++) {
    p[i] = coefBlock[i] * quantizationTable[i];
  }

  // inverse DCT on rows
  var row = 0;
  for (var i = 0; i < 8; ++i, row += 8) {
    // check for all-zero AC coefficients
    if (p[1 + row] == 0 && p[2 + row] == 0 && p[3 + row] == 0 && p[4 + row] == 0 && p[5 + row] == 0 && p[6 + row] == 0 && p[7 + row] == 0) {
      final int t = (sqrt2 * p[0 + row] + 512) >> 10;
      p[row + 0] = t;
      p[row + 1] = t;
      p[row + 2] = t;
      p[row + 3] = t;
      p[row + 4] = t;
      p[row + 5] = t;
      p[row + 6] = t;
      p[row + 7] = t;
      continue;
    }

    // stage 4
    int v0 = (sqrt2 * p[0 + row] + 128) >> 8;
    int v1 = (sqrt2 * p[4 + row] + 128) >> 8;
    int v2 = p[2 + row];
    int v3 = p[6 + row];
    int v4 = (sqrt102 * (p[1 + row] - p[7 + row]) + 128) >> 8;
    int v7 = (sqrt102 * (p[1 + row] + p[7 + row]) + 128) >> 8;
    int v5 = p[3 + row] << 4;
    int v6 = p[5 + row] << 4;

    // stage 3
    int t = (v0 - v1 + 1) >> 1;
    v0 = (v0 + v1 + 1) >> 1;
    v1 = t;
    t = (v2 * sin6 + v3 * cos6 + 128) >> 8;
    v2 = (v2 * cos6 - v3 * sin6 + 128) >> 8;
    v3 = t;
    t = (v4 - v6 + 1) >> 1;
    v4 = (v4 + v6 + 1) >> 1;
    v6 = t;
    t = (v7 + v5 + 1) >> 1;
    v5 = (v7 - v5 + 1) >> 1;
    v7 = t;

    // stage 2
    t = (v0 - v3 + 1) >> 1;
    v0 = (v0 + v3 + 1) >> 1;
    v3 = t;
    t = (v1 - v2 + 1) >> 1;
    v1 = (v1 + v2 + 1) >> 1;
    v2 = t;
    t = (v4 * sin3 + v7 * cos3 + 2048) >> 12;
    v4 = (v4 * cos3 - v7 * sin3 + 2048) >> 12;
    v7 = t;
    t = (v5 * sin1 + v6 * cos1 + 2048) >> 12;
    v5 = (v5 * cos1 - v6 * sin1 + 2048) >> 12;
    v6 = t;

    // stage 1
    p[0 + row] = v0 + v7;
    p[7 + row] = v0 - v7;
    p[1 + row] = v1 + v6;
    p[6 + row] = v1 - v6;
    p[2 + row] = v2 + v5;
    p[5 + row] = v2 - v5;
    p[3 + row] = v3 + v4;
    p[4 + row] = v3 - v4;
  }

  // inverse DCT on columns
  for (var i = 0; i < 8; ++i) {
    final col = i;

    // check for all-zero AC coefficients
    if (p[1 * 8 + col] == 0 && p[2 * 8 + col] == 0 && p[3 * 8 + col] == 0 && p[4 * 8 + col] == 0 && p[5 * 8 + col] == 0 && p[6 * 8 + col] == 0 && p[7 * 8 + col] == 0) {
      final int t = (sqrt2 * dataIn[i] + 8192) >> 14;
      p[0 * 8 + col] = t;
      p[1 * 8 + col] = t;
      p[2 * 8 + col] = t;
      p[3 * 8 + col] = t;
      p[4 * 8 + col] = t;
      p[5 * 8 + col] = t;
      p[6 * 8 + col] = t;
      p[7 * 8 + col] = t;
      continue;
    }

    // stage 4
    int v0 = (sqrt2 * p[0 * 8 + col] + 2048) >> 12;
    int v1 = (sqrt2 * p[4 * 8 + col] + 2048) >> 12;
    int v2 = p[2 * 8 + col];
    int v3 = p[6 * 8 + col];
    int v4 = (sqrt102 * (p[1 * 8 + col] - p[7 * 8 + col]) + 2048) >> 12;
    int v7 = (sqrt102 * (p[1 * 8 + col] + p[7 * 8 + col]) + 2048) >> 12;
    int v5 = p[3 * 8 + col];
    int v6 = p[5 * 8 + col];

    // stage 3
    int t = (v0 - v1 + 1) >> 1;
    v0 = (v0 + v1 + 1) >> 1;
    v1 = t;
    t = (v2 * sin6 + v3 * cos6 + 2048) >> 12;
    v2 = (v2 * cos6 - v3 * sin6 + 2048) >> 12;
    v3 = t;
    t = (v4 - v6 + 1) >> 1;
    v4 = (v4 + v6 + 1) >> 1;
    v6 = t;
    t = (v7 + v5 + 1) >> 1;
    v5 = (v7 - v5 + 1) >> 1;
    v7 = t;

    // stage 2
    t = (v0 - v3 + 1) >> 1;
    v0 = (v0 + v3 + 1) >> 1;
    v3 = t;
    t = (v1 - v2 + 1) >> 1;
    v1 = (v1 + v2 + 1) >> 1;
    v2 = t;
    t = (v4 * sin3 + v7 * cos3 + 2048) >> 12;
    v4 = (v4 * cos3 - v7 * sin3 + 2048) >> 12;
    v7 = t;
    t = (v5 * sin1 + v6 * cos1 + 2048) >> 12;
    v5 = (v5 * cos1 - v6 * sin1 + 2048) >> 12;
    v6 = t;

    // stage 1
    p[0 * 8 + col] = v0 + v7;
    p[7 * 8 + col] = v0 - v7;
    p[1 * 8 + col] = v1 + v6;
    p[6 * 8 + col] = v1 - v6;
    p[2 * 8 + col] = v2 + v5;
    p[5 * 8 + col] = v2 - v5;
    p[3 * 8 + col] = v3 + v4;
    p[4 * 8 + col] = v3 - v4;
  }

  // convert to 8-bit integers
  for (var i = 0; i < 64; ++i) {
    final int index = (_dctClipOffset + 128 + ((p[i] + 8) >> 4)).clamp(0, _dctClipLength - 1);
    dataOut[i] = _dctClip[index];
  }
}

/// Converts decoded JPEG components into an oriented RGBA image.
Image _renderJpeg(_JpegData jpeg) {
  final int orientation = jpeg.orientation;

  final int w = jpeg.width;
  final int h = jpeg.height;
  final bool flipWidthHeight = orientation >= 5 && orientation <= 8;
  final int width = flipWidthHeight ? h : w;
  final int height = flipWidthHeight ? w : h;

  final Image image = Image(width: width, height: height);

  _JpegComponentData component1;
  _JpegComponentData component2;
  _JpegComponentData component3;
  _JpegComponentData component4;
  Uint8List? component1Line;
  Uint8List? component2Line;
  Uint8List? component3Line;
  Uint8List? component4Line;
  bool colorTransform = false;

  switch (jpeg.components.length) {
    case 1:
      component1 = jpeg.components[0];
      final List<Uint8List> lines = component1.lines;
      final int hShift1 = component1.horizontalScaleShift;
      final int vShift1 = component1.verticalScaleShift;
      for (var y = 0; y < h; y++) {
        final int y1 = y >> vShift1;
        component1Line = lines[y1];
        for (var x = 0; x < w; x++) {
          final int x1 = x >> hShift1;
          final int cy = component1Line[x1];

          _setOrientedPixel(
            image: image,
            orientation: orientation,
            sourceWidth: w,
            sourceHeight: h,
            x: x,
            y: y,
            red: cy,
            green: cy,
            blue: cy,
          );
        }
      }
      break;
    case 3:
      colorTransform = jpeg.adobeMarker == null || jpeg.adobeMarker!.transformCode == 1;

      component1 = jpeg.components[0];
      component2 = jpeg.components[1];
      component3 = jpeg.components[2];

      final List<Uint8List> lines1 = component1.lines;
      final List<Uint8List> lines2 = component2.lines;
      final List<Uint8List> lines3 = component3.lines;

      final int hShift1 = component1.horizontalScaleShift;
      final int vShift1 = component1.verticalScaleShift;
      final int hShift2 = component2.horizontalScaleShift;
      final int vShift2 = component2.verticalScaleShift;
      final int hShift3 = component3.horizontalScaleShift;
      final int vShift3 = component3.verticalScaleShift;

      for (var y = 0; y < h; y++) {
        final int y1 = y >> vShift1;
        final int y2 = y >> vShift2;
        final int y3 = y >> vShift3;

        component1Line = lines1[y1];
        component2Line = lines2[y2];
        component3Line = lines3[y3];

        for (var x = 0; x < w; x++) {
          final int x1 = x >> hShift1;
          final int x2 = x >> hShift2;
          final int x3 = x >> hShift3;

          int red = component1Line[x1];
          int green = component2Line[x2];
          int blue = component3Line[x3];
          if (colorTransform) {
            final int luminance = red << 8;
            final int blueDifference = green - 128;
            final int redDifference = blue - 128;
            red = ((luminance + 359 * redDifference + 128) >> 8).clamp(0, 255);
            green = ((luminance - 88 * blueDifference - 183 * redDifference + 128) >> 8).clamp(0, 255);
            blue = ((luminance + 454 * blueDifference + 128) >> 8).clamp(0, 255);
          }

          _setOrientedPixel(
            image: image,
            orientation: orientation,
            sourceWidth: w,
            sourceHeight: h,
            x: x,
            y: y,
            red: red,
            green: green,
            blue: blue,
          );
        }
      }
      break;
    case 4:
      if (jpeg.adobeMarker == null) {
        throw const ImageCodecException('Unsupported color mode (4 components)');
      }
      // The default transform for four components is false
      colorTransform = false;
      // The adobe transform marker overrides any previous setting
      if (jpeg.adobeMarker!.transformCode != 0) {
        colorTransform = true;
      }

      component1 = jpeg.components[0];
      component2 = jpeg.components[1];
      component3 = jpeg.components[2];
      component4 = jpeg.components[3];

      final List<Uint8List> lines1 = component1.lines;
      final List<Uint8List> lines2 = component2.lines;
      final List<Uint8List> lines3 = component3.lines;
      final List<Uint8List> lines4 = component4.lines;

      final int hShift1 = component1.horizontalScaleShift;
      final int vShift1 = component1.verticalScaleShift;
      final int hShift2 = component2.horizontalScaleShift;
      final int vShift2 = component2.verticalScaleShift;
      final int hShift3 = component3.horizontalScaleShift;
      final int vShift3 = component3.verticalScaleShift;
      final int hShift4 = component4.horizontalScaleShift;
      final int vShift4 = component4.verticalScaleShift;

      for (var y = 0; y < jpeg.height; y++) {
        final int y1 = y >> vShift1;
        final int y2 = y >> vShift2;
        final int y3 = y >> vShift3;
        final int y4 = y >> vShift4;
        component1Line = lines1[y1];
        component2Line = lines2[y2];
        component3Line = lines3[y3];
        component4Line = lines4[y4];
        for (var x = 0; x < jpeg.width; x++) {
          final int x1 = x >> hShift1;
          final int x2 = x >> hShift2;
          final int x3 = x >> hShift3;
          final int x4 = x >> hShift4;
          int cc;
          int cm;
          int cy;
          int ck;
          if (!colorTransform) {
            cc = component1Line[x1];
            cm = component2Line[x2];
            cy = component3Line[x3];
            ck = component4Line[x4];
          } else {
            cy = component1Line[x1];
            final int cb = component2Line[x2];
            final int cr = component3Line[x3];
            ck = component4Line[x4];

            cc = 255 - (cy + 1.402 * (cr - 128)).toInt().clamp(0, 255);
            cm = 255 - (cy - 0.3441363 * (cb - 128) - 0.71413636 * (cr - 128)).toInt().clamp(0, 255);
            cy = 255 - (cy + 1.772 * (cb - 128)).toInt().clamp(0, 255);
          }
          final int r = (cc * ck) >> 8;
          final int g = (cm * ck) >> 8;
          final int b = (cy * ck) >> 8;

          _setOrientedPixel(
            image: image,
            orientation: orientation,
            sourceWidth: w,
            sourceHeight: h,
            x: x,
            y: y,
            red: r,
            green: g,
            blue: b,
          );
        }
      }
      break;
    default:
      throw const ImageCodecException('Unsupported color mode');
  }

  return image;
}

/// Writes a source pixel after applying its EXIF [orientation].
void _setOrientedPixel({
  required Image image,
  required int orientation,
  required int sourceWidth,
  required int sourceHeight,
  required int x,
  required int y,
  required int red,
  required int green,
  required int blue,
}) {
  final (int destinationX, int destinationY) = switch (orientation) {
    2 => (sourceWidth - 1 - x, y),
    3 => (sourceWidth - 1 - x, sourceHeight - 1 - y),
    4 => (x, sourceHeight - 1 - y),
    5 => (y, x),
    6 => (sourceHeight - 1 - y, x),
    7 => (sourceHeight - 1 - y, sourceWidth - 1 - x),
    8 => (y, sourceWidth - 1 - x),
    _ => (x, y),
  };
  image.setPixelRgb(destinationX, destinationY, red, green, blue);
}
