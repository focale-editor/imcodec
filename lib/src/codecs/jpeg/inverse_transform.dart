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
  final int sourceWidth = jpeg.width;
  final int sourceHeight = jpeg.height;
  final int orientation = jpeg.orientation;
  final bool swapsAxes = orientation >= 5 && orientation <= 8;
  final Image image = Image(
    width: swapsAxes ? sourceHeight : sourceWidth,
    height: swapsAxes ? sourceWidth : sourceHeight,
  );
  final Uint8List rgba = _renderComponents(jpeg, sourceWidth, sourceHeight);
  if (orientation == 1) {
    image.bytes.setAll(0, rgba);
    return image;
  }
  _applyOrientation(rgba, image.bytes, sourceWidth, sourceHeight, orientation, image.width);
  return image;
}

/// Converts component samples to opaque RGBA pixels in stream order.
Uint8List _renderComponents(_JpegData jpeg, int width, int height) {
  final Uint8List rgba = Uint8List(width * height * 4);
  switch (jpeg.components.length) {
    case 1:
      _renderGrayscale(jpeg.components[0], rgba, width, height);
    case 3:
      _renderYCbCr(
        jpeg.components[0],
        jpeg.components[1],
        jpeg.components[2],
        rgba,
        width,
        height,
        colorTransform: jpeg.adobeMarker == null || jpeg.adobeMarker!.transformCode != 0,
      );
    case 4:
      final _JpegAdobeMarker? adobeMarker = jpeg.adobeMarker;
      if (adobeMarker == null) {
        throw const ImageCodecException('Four-component JPEG data requires an Adobe marker');
      }
      _renderCmyk(
        jpeg.components[0],
        jpeg.components[1],
        jpeg.components[2],
        jpeg.components[3],
        rgba,
        width,
        height,
        colorTransform: adobeMarker.transformCode != 0,
      );
    default:
      throw const ImageCodecException('Unsupported JPEG color mode');
  }
  return rgba;
}

/// Expands one luminance component to gray RGBA pixels.
void _renderGrayscale(_JpegComponentData component, Uint8List rgba, int width, int height) {
  final Uint8List plane = component.plane;
  int destination = 0;
  for (int sample = 0; sample < width * height; sample++) {
    final int gray = plane[sample];
    rgba[destination] = gray;
    rgba[destination + 1] = gray;
    rgba[destination + 2] = gray;
    rgba[destination + 3] = 255;
    destination += 4;
  }
}

/// Converts three components to RGBA, optionally undoing the YCbCr transform.
void _renderYCbCr(
  _JpegComponentData luminance,
  _JpegComponentData blueChroma,
  _JpegComponentData redChroma,
  Uint8List rgba,
  int width,
  int height, {
  required bool colorTransform,
}) {
  final Uint8List clip = _dctClip;
  final Uint8List luminancePlane = luminance.plane;
  final Uint8List bluePlane = blueChroma.plane;
  final Uint8List redPlane = redChroma.plane;
  final int sampleCount = width * height;
  int destination = 0;
  for (int sample = 0; sample < sampleCount; sample++) {
    if (colorTransform) {
      final int scaledLuminance = luminancePlane[sample] << 8;
      final int blueDifference = bluePlane[sample] - 128;
      final int redDifference = redPlane[sample] - 128;
      rgba[destination] = clip[_dctClipOffset + ((scaledLuminance + 359 * redDifference + 128) >> 8)];
      rgba[destination + 1] = clip[_dctClipOffset + ((scaledLuminance - 88 * blueDifference - 183 * redDifference + 128) >> 8)];
      rgba[destination + 2] = clip[_dctClipOffset + ((scaledLuminance + 454 * blueDifference + 128) >> 8)];
    } else {
      rgba[destination] = luminancePlane[sample];
      rgba[destination + 1] = bluePlane[sample];
      rgba[destination + 2] = redPlane[sample];
    }
    rgba[destination + 3] = 255;
    destination += 4;
  }
}

/// Converts four components to RGBA through the Adobe CMYK inversion.
void _renderCmyk(
  _JpegComponentData first,
  _JpegComponentData second,
  _JpegComponentData third,
  _JpegComponentData fourth,
  Uint8List rgba,
  int width,
  int height, {
  required bool colorTransform,
}) {
  final Uint8List clip = _dctClip;
  final Uint8List firstPlane = first.plane;
  final Uint8List secondPlane = second.plane;
  final Uint8List thirdPlane = third.plane;
  final Uint8List fourthPlane = fourth.plane;
  final int sampleCount = width * height;
  int destination = 0;
  for (int sample = 0; sample < sampleCount; sample++) {
    int cyan = firstPlane[sample];
    int magenta = secondPlane[sample];
    int yellow = thirdPlane[sample];
    final int black = fourthPlane[sample];
    if (colorTransform) {
      final int scaledLuminance = cyan << 8;
      final int blueDifference = magenta - 128;
      final int redDifference = yellow - 128;
      cyan = 255 - clip[_dctClipOffset + ((scaledLuminance + 359 * redDifference + 128) >> 8)];
      magenta = 255 - clip[_dctClipOffset + ((scaledLuminance - 88 * blueDifference - 183 * redDifference + 128) >> 8)];
      yellow = 255 - clip[_dctClipOffset + ((scaledLuminance + 454 * blueDifference + 128) >> 8)];
    }
    rgba[destination] = (cyan * black + 127) ~/ 255;
    rgba[destination + 1] = (magenta * black + 127) ~/ 255;
    rgba[destination + 2] = (yellow * black + 127) ~/ 255;
    rgba[destination + 3] = 255;
    destination += 4;
  }
}

/// Copies pixels into their oriented positions on the destination canvas.
void _applyOrientation(
  Uint8List source,
  Uint8List destination,
  int width,
  int height,
  int orientation,
  int destinationWidth,
) {
  int sourceOffset = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final (int destinationX, int destinationY) = switch (orientation) {
        2 => (width - 1 - x, y),
        3 => (width - 1 - x, height - 1 - y),
        4 => (x, height - 1 - y),
        5 => (y, x),
        6 => (height - 1 - y, x),
        7 => (height - 1 - y, width - 1 - x),
        8 => (y, width - 1 - x),
        _ => (x, y),
      };
      final int destinationOffset = (destinationY * destinationWidth + destinationX) * 4;
      destination[destinationOffset] = source[sourceOffset];
      destination[destinationOffset + 1] = source[sourceOffset + 1];
      destination[destinationOffset + 2] = source[sourceOffset + 2];
      destination[destinationOffset + 3] = source[sourceOffset + 3];
      sourceOffset += 4;
    }
  }
}
