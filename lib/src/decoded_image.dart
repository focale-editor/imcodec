import 'dart:typed_data';

import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';

/// Identifies the process channels retained by a decoded raster.
enum DecodedColorModel {
  /// Red, green, and blue process channels.
  rgb(processChannelCount: 3),

  /// Cyan, magenta, yellow, and black process channels.
  cmyk(processChannelCount: 4);

  /// Number of process channels before alpha.
  final int processChannelCount;

  /// Creates a decoded colour model with its channel count.
  const DecodedColorModel({required this.processChannelCount});
}

/// Identifies the scalar representation of decoded channel samples.
enum DecodedSampleFormat {
  /// Unsigned normalized eight-bit integers.
  uint8(bitsPerChannel: 8, bytesPerChannel: 1),

  /// Unsigned normalized sixteen-bit integers.
  uint16(bitsPerChannel: 16, bytesPerChannel: 2),

  /// IEEE-754 single-precision values, normally normalized but HDR-capable.
  float32(bitsPerChannel: 32, bytesPerChannel: 4);

  /// Significant storage depth of one channel.
  final int bitsPerChannel;

  /// Bytes occupied by one channel.
  final int bytesPerChannel;

  /// Creates a decoded sample representation.
  const DecodedSampleFormat({
    required this.bitsPerChannel,
    required this.bytesPerChannel,
  });
}

/// Describes metadata that affects faithful raster decoding.
final class DecodedImageMetadata {
  /// Width before any orientation that swaps axes.
  final int width;

  /// Height before any orientation that swaps axes.
  final int height;

  /// Number of significant bits declared for each process channel.
  final int bitsPerChannel;

  /// Process colour model declared by the container.
  final DecodedColorModel colorModel;

  /// Embedded ICC payload, when present.
  final Uint8List? iccProfile;

  /// Creates immutable decoded-image metadata.
  DecodedImageMetadata({
    required this.width,
    required this.height,
    required this.bitsPerChannel,
    required this.colorModel,
    Uint8List? iccProfile,
  }) : iccProfile = iccProfile == null ? null : Uint8List.fromList(iccProfile).asUnmodifiableView();

  /// Whether generic RGBA8 platform decoding would discard authored data.
  bool get requiresExactDecoding => bitsPerChannel > 8 || colorModel == DecodedColorModel.cmyk || iccProfile != null;
}

/// Stores straight-alpha process samples without reducing their precision.
///
/// Pixels are tightly interleaved as RGB+A or CMYK+A. Unsigned sixteen-bit
/// and floating-point samples use little-endian byte order so the result is
/// stable across platforms and transferable between isolates.
final class DecodedImage {
  /// Width after applying encoded orientation.
  final int width;

  /// Height after applying encoded orientation.
  final int height;

  /// Process colour model represented by [bytes].
  final DecodedColorModel colorModel;

  /// Scalar representation of every channel in [bytes].
  final DecodedSampleFormat sampleFormat;

  /// Embedded ICC payload, when present.
  final Uint8List? iccProfile;

  /// Immutable tightly packed process-plus-alpha bytes.
  final Uint8List bytes;

  /// Creates a decoded raster and validates its exact byte length.
  DecodedImage({
    required this.width,
    required this.height,
    required this.colorModel,
    required this.sampleFormat,
    Uint8List? iccProfile,
    required Uint8List bytes,
    bool copy = true,
  }) : iccProfile = iccProfile == null ? null : Uint8List.fromList(iccProfile).asUnmodifiableView(),
       bytes = (copy ? Uint8List.fromList(bytes) : bytes).asUnmodifiableView() {
    if (width < 1 || height < 1) {
      throw const ImageCodecException(
        'Decoded image dimensions must be positive and non-zero',
      );
    }
    final int expected = width * height * bytesPerPixel;
    if (this.bytes.lengthInBytes != expected) {
      throw ImageCodecException(
        'Expected $expected decoded bytes, received ${this.bytes.lengthInBytes}',
      );
    }
  }

  /// Creates an eight-bit decoded raster from an existing [image].
  factory DecodedImage.fromImage(
    Image image, {
    Uint8List? iccProfile,
  }) => DecodedImage(
    width: image.width,
    height: image.height,
    colorModel: DecodedColorModel.rgb,
    sampleFormat: DecodedSampleFormat.uint8,
    iccProfile: iccProfile,
    bytes: image.bytes,
  );

  /// Total process and alpha channels stored for one pixel.
  int get channelCount => colorModel.processChannelCount + 1;

  /// Offset of the straight alpha sample inside one pixel.
  int get alphaChannelIndex => colorModel.processChannelCount;

  /// Bytes occupied by one complete pixel.
  int get bytesPerPixel => channelCount * sampleFormat.bytesPerChannel;

  /// Returns a copy with [profile] attached without rewriting samples.
  DecodedImage withIccProfile(Uint8List? profile) => DecodedImage(
    width: width,
    height: height,
    colorModel: colorModel,
    sampleFormat: sampleFormat,
    iccProfile: profile,
    bytes: bytes,
    copy: false,
  );

  /// Reorders tightly packed pixels for one TIFF or EXIF orientation.
  ///
  /// [source] holds [width] by [height] pixels of [bytesPerPixel] bytes each.
  /// The result is always a fresh buffer, and its axes are swapped when
  /// [orientation] is five or greater. Decoders call this directly when they
  /// still own their samples; [oriented] wraps it for decoded rasters.
  static Uint8List orientPixels(
    Uint8List source, {
    required int width,
    required int height,
    required int bytesPerPixel,
    required int orientation,
  }) {
    if (orientation < 1 || orientation > 8) {
      throw ImageCodecException('Unsupported image orientation: $orientation');
    }
    final Uint8List output = Uint8List(source.lengthInBytes);
    if (orientation == 1) {
      output.setAll(0, source);
      return output;
    }
    final int outputWidth = orientation >= 5 ? height : width;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final (int outputX, int outputY) = switch (orientation) {
          2 => (width - 1 - x, y),
          3 => (width - 1 - x, height - 1 - y),
          4 => (x, height - 1 - y),
          5 => (y, x),
          6 => (height - 1 - y, x),
          7 => (height - 1 - y, width - 1 - x),
          8 => (y, width - 1 - x),
          _ => (x, y),
        };
        final int from = (y * width + x) * bytesPerPixel;
        final int to = (outputY * outputWidth + outputX) * bytesPerPixel;
        output.setRange(to, to + bytesPerPixel, source, from);
      }
    }
    return output;
  }

  /// Applies one TIFF or EXIF orientation without changing sample values.
  DecodedImage oriented(int orientation) {
    if (orientation < 1 || orientation > 8) {
      throw ImageCodecException('Unsupported image orientation: $orientation');
    }
    if (orientation == 1) {
      return this;
    }
    return DecodedImage(
      width: orientation >= 5 ? height : width,
      height: orientation >= 5 ? width : height,
      colorModel: colorModel,
      sampleFormat: sampleFormat,
      iccProfile: iccProfile,
      bytes: orientPixels(
        bytes,
        width: width,
        height: height,
        bytesPerPixel: bytesPerPixel,
        orientation: orientation,
      ),
      copy: false,
    );
  }

  /// Produces the conventional eight-bit RGB view used by existing encoders.
  Image toImage() {
    if (colorModel == DecodedColorModel.rgb && sampleFormat == DecodedSampleFormat.uint8) {
      return Image.fromRgba(
        width: width,
        height: height,
        bytes: Uint8List.fromList(bytes),
        copy: false,
      );
    }
    final Uint8List rgba = Uint8List(width * height * 4);
    final ByteData data = ByteData.sublistView(bytes);
    for (int pixel = 0; pixel < width * height; pixel++) {
      final int source = pixel * bytesPerPixel;
      final int destination = pixel * 4;
      final double alpha = _sample(data, source, alphaChannelIndex);
      if (colorModel == DecodedColorModel.rgb) {
        rgba[destination] = _toByte(_sample(data, source, 0));
        rgba[destination + 1] = _toByte(_sample(data, source, 1));
        rgba[destination + 2] = _toByte(_sample(data, source, 2));
      } else {
        final double black = _bounded(_sample(data, source, 3));
        rgba[destination] = _toByte(
          (1 - _bounded(_sample(data, source, 0))) * (1 - black),
        );
        rgba[destination + 1] = _toByte(
          (1 - _bounded(_sample(data, source, 1))) * (1 - black),
        );
        rgba[destination + 2] = _toByte(
          (1 - _bounded(_sample(data, source, 2))) * (1 - black),
        );
      }
      rgba[destination + 3] = _toByte(alpha);
    }
    return Image.fromRgba(
      width: width,
      height: height,
      bytes: rgba,
      copy: false,
    );
  }

  /// Reads one channel as a normalized or floating-point scalar.
  double _sample(ByteData data, int pixelOffset, int channel) {
    final int offset = pixelOffset + channel * sampleFormat.bytesPerChannel;
    return switch (sampleFormat) {
      DecodedSampleFormat.uint8 => bytes[offset] / 255,
      DecodedSampleFormat.uint16 => data.getUint16(offset, Endian.little) / 65535,
      DecodedSampleFormat.float32 => data.getFloat32(offset, Endian.little),
    };
  }

  /// Quantizes one finite normalized value to a display byte.
  static int _toByte(double value) => (_bounded(value) * 255).round().clamp(0, 255);

  /// Bounds one sample for conversion to conventional display RGB.
  static double _bounded(double value) => (value.isFinite ? value : 0).clamp(0, 1).toDouble();
}
