import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';

/// A decoded JPEG XL image: per-channel planes (already oriented) plus the
/// image metadata.
final class JpegXlDecodedImage {
  /// True for reduced-resolution previews from [JpegXlStreamingDecoder].
  final bool isPreview;

  /// Width overriding the oriented header for reduced-resolution output.
  final int? _widthOverride;

  /// Height overriding the oriented header for reduced-resolution output.
  final int? _heightOverride;

  /// Parsed metadata describing the decoded image.
  final ImageHeader _header;

  /// Decoded planes: color channels first, then extra channels.
  final List<ImageBuffer> channels;

  /// The decompressed ICC profile embedded in the codestream, if any.
  final Uint8List? iccProfile;

  /// Creates a full-resolution decoded image for internal codec use.
  JpegXlDecodedImage.internal({required this._header, required this.channels, required this.iccProfile}) : isPreview = false, _widthOverride = null, _heightOverride = null;

  /// Creates a reduced-resolution progressive preview.
  JpegXlDecodedImage.preview({required this._header, required this.channels, required this.iccProfile, required int width, required int height})
    : isPreview = true,
      _widthOverride = width,
      _heightOverride = height;

  /// Creates a caller-requested reduced-resolution image.
  ///
  /// Unlike [JpegXlDecodedImage.preview], this is the final requested output rather
  /// than a placeholder to be superseded by a later full decode.
  JpegXlDecodedImage.scaled({required this._header, required this.channels, required this.iccProfile, required int width, required int height})
    : isPreview = false,
      _widthOverride = width,
      _heightOverride = height;

  /// Output width after orientation and optional scaling.
  int get width => _widthOverride ?? _header.orientedSize.width;

  /// Output height after orientation and optional scaling.
  int get height => _heightOverride ?? _header.orientedSize.height;

  /// Whether the image has one grayscale color channel.
  bool get isGrayscale => _header.isGrayscale;

  /// Whether the image carries an alpha channel.
  bool get hasAlpha => _header.hasAlpha;

  /// Number of significant bits in each color sample.
  int get bitsPerSample => _header.bitDepth.bitsPerSample;

  /// The parsed image header, for internal/advanced use.
  ImageHeader get header => _header;

  /// Converts to interleaved 8-bit RGBA in sRGB, top-left origin.
  Uint8List toRgba8() {
    final int w = width;
    final int h = height;
    final out = Uint8List(w * h * 4);
    final int colors = _header.colorChannelCount;
    final int maxValue = _header.bitDepth.maxValue;
    final int alphaIndex = _header.alphaIndices.isNotEmpty ? _header.alphaIndices.first : -1;
    final ImageBuffer? alphaChannel = alphaIndex >= 0 ? channels[colors + alphaIndex] : null;
    final int alphaMax = alphaIndex >= 0 ? _header.extraChannels[alphaIndex].bitDepth.maxValue : 1;

    int scaleInt(int value, int max) {
      int v = value;
      if (v < 0) {
        v = 0;
      }
      if (v > max) {
        v = max;
      }
      if (max == 255) {
        return v;
      }
      return (v * 255 + (max >> 1)) ~/ max;
    }

    int sample(ImageBuffer plane, int y, int x, int max) {
      if (plane.isInt) {
        return scaleInt(plane.intRows[y][x], max);
      }
      final double f = plane.floatRows[y][x];
      final int v = (f * 255 + 0.5).floor();
      return v < 0
          ? 0
          : v > 255
          ? 255
          : v;
    }

    final ImageBuffer r = channels[0];
    final ImageBuffer g = channels[colors > 1 ? 1 : 0];
    final ImageBuffer b = channels[colors > 1 ? 2 : 0];
    var o = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out[o] = sample(r, y, x, maxValue);
        out[o + 1] = sample(g, y, x, maxValue);
        out[o + 2] = sample(b, y, x, maxValue);
        out[o + 3] = alphaChannel != null ? sample(alphaChannel, y, x, alphaMax) : 255;
        o += 4;
      }
    }
    return out;
  }
}

/// All visible frames of a decoded (possibly animated) JPEG XL image.
final class JpegXlDecodedAnimation {
  /// Finalized frames, in presentation order.
  final List<JpegXlDecodedImage> frames;

  /// Per-frame durations in ticks ([tpsNumerator] / [tpsDenominator] ticks
  /// per second). Zero for still images.
  final List<int> durations;

  /// Per-frame timecodes (only meaningful when the stream has timecodes).
  final List<int> timecodes;

  /// Numerator of the animation tick rate (ticks per second).
  final int tpsNumerator;

  /// Denominator of the animation tick rate (ticks per second).
  final int tpsDenominator;

  /// Number of animation loops; 0 means loop forever.
  final int numLoops;

  /// Creates an animation assembled by the JPEG XL decoder.
  JpegXlDecodedAnimation.internal({required this.frames, required this.durations, required this.timecodes, required this.tpsNumerator, required this.tpsDenominator, required this.numLoops});

  /// Whether this image has more than one frame.
  bool get isAnimated => frames.length > 1;

  /// Wall-clock duration of frame [index].
  Duration frameDuration(int index) {
    if (tpsNumerator == 0) {
      return Duration.zero;
    }
    return Duration(microseconds: durations[index] * tpsDenominator * 1000000 ~/ tpsNumerator);
  }
}
