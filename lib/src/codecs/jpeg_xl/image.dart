import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';

/// Represents one decoded and correctly oriented JPEG XL image.
final class JpegXlDecodedImage {
  /// Whether this image is a replaceable progressive preview.
  final bool isPreview;

  /// Width overriding the oriented header for reduced-resolution output.
  final int? _widthOverride;

  /// Height overriding the oriented header for reduced-resolution output.
  final int? _heightOverride;

  /// Parsed metadata describing the decoded image.
  final ImageHeader _header;

  /// Decoded planes with color channels followed by extra channels.
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
    final int outputWidth = width;
    final int outputHeight = height;
    final Uint8List output = Uint8List(outputWidth * outputHeight * 4);
    final int colorChannelCount = _header.colorChannelCount;
    final int maximumSampleValue = _header.bitDepth.maxValue;
    final int alphaExtraChannelIndex = _header.alphaIndices.isNotEmpty ? _header.alphaIndices.first : -1;
    final ImageBuffer? alphaChannel = alphaExtraChannelIndex >= 0 ? channels[colorChannelCount + alphaExtraChannelIndex] : null;
    final int maximumAlphaValue = alphaExtraChannelIndex >= 0 ? _header.extraChannels[alphaExtraChannelIndex].bitDepth.maxValue : 1;

    /// Scales an integer sample to the unsigned eight-bit range.
    int scaleInteger(int value, int maximum) {
      int clampedValue = value;
      if (clampedValue < 0) {
        clampedValue = 0;
      }
      if (clampedValue > maximum) {
        clampedValue = maximum;
      }
      if (maximum == 255) {
        return clampedValue;
      }
      return (clampedValue * 255 + (maximum >> 1)) ~/ maximum;
    }

    /// Reads and scales one sample from [plane].
    int sample(ImageBuffer plane, int row, int column, int maximum) {
      if (plane.isInt) {
        return scaleInteger(plane.intRows[row][column], maximum);
      }
      final double floatSample = plane.floatRows[row][column];
      final int scaledValue = (floatSample * 255 + 0.5).floor();
      return scaledValue < 0
          ? 0
          : scaledValue > 255
          ? 255
          : scaledValue;
    }

    final ImageBuffer redChannel = channels[0];
    final ImageBuffer greenChannel = channels[colorChannelCount > 1 ? 1 : 0];
    final ImageBuffer blueChannel = channels[colorChannelCount > 1 ? 2 : 0];
    int outputOffset = 0;
    for (int row = 0; row < outputHeight; row++) {
      for (int column = 0; column < outputWidth; column++) {
        output[outputOffset] = sample(redChannel, row, column, maximumSampleValue);
        output[outputOffset + 1] = sample(greenChannel, row, column, maximumSampleValue);
        output[outputOffset + 2] = sample(blueChannel, row, column, maximumSampleValue);
        output[outputOffset + 3] = alphaChannel != null ? sample(alphaChannel, row, column, maximumAlphaValue) : 255;
        outputOffset += 4;
      }
    }
    return output;
  }
}

/// Represents the visible frames and timing of a decoded JPEG XL animation.
final class JpegXlDecodedAnimation {
  /// Finalized frames, in presentation order.
  final List<JpegXlDecodedImage> frames;

  /// Duration of each frame in animation ticks.
  final List<int> frameDurations;

  /// Timecode associated with each frame when present in the codestream.
  final List<int> frameTimecodes;

  /// Numerator of the animation tick rate (ticks per second).
  final int ticksPerSecondNumerator;

  /// Denominator of the animation tick rate (ticks per second).
  final int ticksPerSecondDenominator;

  /// Number of animation loops; 0 means loop forever.
  final int loopCount;

  /// Creates an animation assembled by the JPEG XL decoder.
  JpegXlDecodedAnimation.internal({
    required this.frames,
    required this.frameDurations,
    required this.frameTimecodes,
    required this.ticksPerSecondNumerator,
    required this.ticksPerSecondDenominator,
    required this.loopCount,
  });

  /// Whether this image has more than one frame.
  bool get isAnimated => frames.length > 1;

  /// Wall-clock duration of frame [index].
  Duration frameDuration(int index) {
    if (ticksPerSecondNumerator == 0) {
      return Duration.zero;
    }
    return Duration(microseconds: frameDurations[index] * ticksPerSecondDenominator * 1000000 ~/ ticksPerSecondNumerator);
  }
}
