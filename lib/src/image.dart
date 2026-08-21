import 'dart:typed_data';

import 'package:imcodec/src/image_codec_exception.dart';

/// Describes the channel layout of source pixel bytes.
enum ChannelOrder {
  /// A single red, or grayscale, channel.
  red(1),

  /// Grayscale followed by alpha.
  grayAlpha(2),

  /// Red, green, and blue.
  rgb(3),

  /// Blue, green, and red.
  bgr(3),

  /// Red, green, blue, and alpha.
  rgba(4),

  /// Blue, green, red, and alpha.
  bgra(4),

  /// Alpha, red, green, and blue.
  argb(4),

  /// Alpha, blue, green, and red.
  abgr(4);

  /// Number of bytes occupied by one pixel.
  final int channelCount;

  /// Creates a channel order from the number of channels.
  const ChannelOrder(this.channelCount);
}

/// Stores an 8-bit image in straight-alpha RGBA order.
final class Image {
  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// The raw bytes of the image.
  final Uint8List _rgba;

  /// Creates a transparent RGBA image.
  Image({
    required this.width,
    required this.height,
  }) : _rgba = _allocate(width, height);

  /// Creates an image from tightly packed or row-strided channel bytes.
  ///
  /// The source is normalized to straight-alpha RGBA. One-channel inputs are
  /// interpreted as grayscale and two-channel inputs as grayscale plus alpha.
  factory Image.fromBytes({
    required int width,
    required int height,
    required ByteBuffer bytes,
    int bytesOffset = 0,
    int? numChannels,
    int? rowStride,
    ChannelOrder? order,
  }) {
    _validateDimensions(width, height);
    if (bytesOffset < 0 || bytesOffset > bytes.lengthInBytes) {
      throw RangeError.range(bytesOffset, 0, bytes.lengthInBytes, 'bytesOffset');
    }

    final int channelCount = numChannels ?? order?.channelCount ?? 3;
    if (channelCount < 1 || channelCount > 4) {
      throw RangeError.range(channelCount, 1, 4, 'numChannels');
    }
    final ChannelOrder sourceOrder = order ?? _defaultOrder(channelCount);
    if (sourceOrder.channelCount != channelCount) {
      throw ArgumentError.value(order, 'order', 'Channel order does not match numChannels');
    }

    final int packedStride = width * channelCount;
    final int sourceStride = rowStride ?? packedStride;
    if (sourceStride < packedStride) {
      throw RangeError.range(sourceStride, packedStride, null, 'rowStride');
    }
    final int requiredBytes = (height - 1) * sourceStride + packedStride;
    if (requiredBytes > bytes.lengthInBytes - bytesOffset) {
      throw ImageCodecException('The source buffer is too small for a $width x $height image');
    }

    final Uint8List source = Uint8List.view(bytes, bytesOffset, requiredBytes);
    final Uint8List rgba = _allocate(width, height);
    for (int y = 0; y < height; y++) {
      int sourceOffset = y * sourceStride;
      int destinationOffset = y * width * 4;
      for (int x = 0; x < width; x++) {
        switch (sourceOrder) {
          case ChannelOrder.red:
            final int gray = source[sourceOffset];
            rgba[destinationOffset] = gray;
            rgba[destinationOffset + 1] = gray;
            rgba[destinationOffset + 2] = gray;
            rgba[destinationOffset + 3] = 255;
          case ChannelOrder.grayAlpha:
            final int gray = source[sourceOffset];
            rgba[destinationOffset] = gray;
            rgba[destinationOffset + 1] = gray;
            rgba[destinationOffset + 2] = gray;
            rgba[destinationOffset + 3] = source[sourceOffset + 1];
          case ChannelOrder.rgb:
            rgba[destinationOffset] = source[sourceOffset];
            rgba[destinationOffset + 1] = source[sourceOffset + 1];
            rgba[destinationOffset + 2] = source[sourceOffset + 2];
            rgba[destinationOffset + 3] = 255;
          case ChannelOrder.bgr:
            rgba[destinationOffset] = source[sourceOffset + 2];
            rgba[destinationOffset + 1] = source[sourceOffset + 1];
            rgba[destinationOffset + 2] = source[sourceOffset];
            rgba[destinationOffset + 3] = 255;
          case ChannelOrder.rgba:
            rgba.setRange(destinationOffset, destinationOffset + 4, source, sourceOffset);
          case ChannelOrder.bgra:
            rgba[destinationOffset] = source[sourceOffset + 2];
            rgba[destinationOffset + 1] = source[sourceOffset + 1];
            rgba[destinationOffset + 2] = source[sourceOffset];
            rgba[destinationOffset + 3] = source[sourceOffset + 3];
          case ChannelOrder.argb:
            rgba[destinationOffset] = source[sourceOffset + 1];
            rgba[destinationOffset + 1] = source[sourceOffset + 2];
            rgba[destinationOffset + 2] = source[sourceOffset + 3];
            rgba[destinationOffset + 3] = source[sourceOffset];
          case ChannelOrder.abgr:
            rgba[destinationOffset] = source[sourceOffset + 3];
            rgba[destinationOffset + 1] = source[sourceOffset + 2];
            rgba[destinationOffset + 2] = source[sourceOffset + 1];
            rgba[destinationOffset + 3] = source[sourceOffset];
        }
        sourceOffset += channelCount;
        destinationOffset += 4;
      }
    }
    return Image._(width, height, rgba);
  }

  /// Creates an image from straight-alpha RGBA bytes.
  ///
  /// Set [copy] to `false` to transfer ownership of [bytes] without allocating.
  factory Image.fromRgba({required int width, required int height, required Uint8List bytes, bool copy = true}) {
    _validateDimensions(width, height);
    final int expectedLength = width * height * 4;
    if (bytes.length != expectedLength) {
      throw ImageCodecException('Expected $expectedLength RGBA bytes, received ${bytes.length}');
    }
    return Image._(width, height, copy ? Uint8List.fromList(bytes) : bytes);
  }

  /// Creates an image around an already validated RGBA buffer.
  Image._(this.width, this.height, this._rgba);

  /// Number of stored channels per pixel.
  int get numChannels => 4;

  /// Mutable straight-alpha RGBA bytes.
  ///
  /// The returned buffer is owned by this image. Mutations immediately affect
  /// subsequent encodes.
  Uint8List get bytes => _rgba;

  /// Changes one pixel using 8-bit channel values.
  void setPixelRgba(int x, int y, int red, int green, int blue, int alpha) {
    final int offset = _pixelOffset(x, y);
    _rgba[offset] = red;
    _rgba[offset + 1] = green;
    _rgba[offset + 2] = blue;
    _rgba[offset + 3] = alpha;
  }

  /// Returns the red channel at [x], [y].
  int red(int x, int y) => _rgba[_pixelOffset(x, y)];

  /// Returns the green channel at [x], [y].
  int green(int x, int y) => _rgba[_pixelOffset(x, y) + 1];

  /// Returns the blue channel at [x], [y].
  int blue(int x, int y) => _rgba[_pixelOffset(x, y) + 2];

  /// Returns the alpha channel at [x], [y].
  int alpha(int x, int y) => _rgba[_pixelOffset(x, y) + 3];

  /// Resolves [x] and [y] to an RGBA byte offset after bounds checking.
  int _pixelOffset(int x, int y) {
    if (x < 0 || x >= width) {
      throw RangeError.range(x, 0, width - 1, 'x');
    }
    if (y < 0 || y >= height) {
      throw RangeError.range(y, 0, height - 1, 'y');
    }
    return (y * width + x) * 4;
  }

  /// Allocates a zero-filled RGBA buffer for validated dimensions.
  static Uint8List _allocate(int width, int height) {
    _validateDimensions(width, height);
    return Uint8List(width * height * 4);
  }

  /// Ensures both image dimensions can describe at least one pixel.
  static void _validateDimensions(int width, int height) {
    if (width < 1) {
      throw RangeError.range(width, 1, null, 'width');
    }
    if (height < 1) {
      throw RangeError.range(height, 1, null, 'height');
    }
  }

  /// Chooses the conventional layout for a source channel count.
  static ChannelOrder _defaultOrder(int channelCount) => switch (channelCount) {
    1 => ChannelOrder.red,
    2 => ChannelOrder.grayAlpha,
    3 => ChannelOrder.rgb,
    4 => ChannelOrder.rgba,
    _ => throw StateError('Unsupported channel count'),
  };
}
