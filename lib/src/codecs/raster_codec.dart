import 'dart:convert';
import 'dart:typed_data';

import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';
import 'package:imcodec/src/parallel_runner.dart';

/// Default maximum number of pixels accepted by raster decoders.
const int defaultMaxPixels = 100000000;

/// Converts encoded raster bytes to an [Image].
abstract base class RasterDecoder extends Converter<Uint8List, Image> {
  /// Creates a raster decoder.
  const RasterDecoder();

  /// Decodes [input] to an image.
  Image decode(Uint8List input, {required int maxPixels});

  @override
  Image convert(Uint8List input) => decode(input, maxPixels: defaultMaxPixels);
}

/// Converts an [Image] to encoded raster bytes.
abstract base class RasterEncoder extends Converter<Image, Uint8List> {
  /// Creates a raster encoder.
  const RasterEncoder();

  /// Encodes [input] to raster bytes.
  Uint8List encode(Image input);

  @override
  Uint8List convert(Image input) => encode(input);
}

/// Provides shared validation and error handling for synchronous image codecs.
abstract base class RasterCodec<Encoder extends RasterEncoder, Decoder extends RasterDecoder> extends Codec<Image, Uint8List> {
  /// Format accepted and produced by this codec.
  final ImageFormat format;

  /// Maximum number of pixels that decoding may allocate.
  final int maxPixels;

  /// Creates a codec for [format] with a bounded decoding allocation.
  const RasterCodec({
    required this.format,
    this.maxPixels = defaultMaxPixels,
  });

  /// Encoder configured with this codec's output options.
  Encoder get rasterEncoder;

  /// Decoder used after shared input validation.
  Decoder get rasterDecoder;

  @override
  Encoder get encoder => rasterEncoder;

  @override
  Converter<Uint8List, Image> get decoder => _RasterCodecConverter(codec: this);

  @override
  Image decode(Uint8List encoded) {
    if (maxPixels < 1) {
      throw RangeError.range(maxPixels, 1, null, 'maxPixels');
    }
    final ImageFormat? actualFormat = ImageFormat.sniff(encoded);
    if (actualFormat != format) {
      throw ImageCodecException('Expected ${format.name} data, found ${actualFormat?.name ?? 'an unknown format'}');
    }
    try {
      return decodeBytes(encoded);
    } on ImageCodecException {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException('Could not decode the ${format.name} image', cause: error);
    }
  }

  @override
  Uint8List encode(Image input) {
    try {
      return encodeImage(input);
    } on ImageCodecException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException('Could not encode the ${format.name} image', cause: error);
    }
  }

  /// Decodes bytes after shared format and allocation-option validation.
  Image decodeBytes(Uint8List encoded) => rasterDecoder.decode(encoded, maxPixels: maxPixels);

  /// Encodes an image while format-specific options are in effect.
  Uint8List encodeImage(Image image) => rasterEncoder.encode(image);

  /// Rejects dimensions that exceed [maxPixels] before allocating pixels.
  void checkDecodedDimensions(int width, int height) {
    if (width < 1 || height < 1) {
      throw const ImageCodecException('Image dimensions must be positive and non-zero');
    }
    final int pixelCount = width * height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
  }
}

/// Applies a codec's decoding configuration through the converter interface.
final class _RasterCodecConverter extends Converter<Uint8List, Image> {
  /// Codec that performs the conversion.
  final RasterCodec codec;

  /// Creates a decoder backed by [codec].
  const _RasterCodecConverter({
    required this.codec,
  });

  @override
  Image convert(Uint8List input) => codec.decode(input);
}

/// A codec that can spread work across isolates.
base mixin ParallelRasterCodec<Encoder extends ParallelRasterEncoder, Decoder extends RasterDecoder> on RasterCodec<Encoder, Decoder> {
  /// Encodes [input], offering [runner] the parts that can run independently.
  ///
  /// The bytes match [encode]'s exactly, so passing a runner can only make
  /// encoding faster, never different. JPEG, JPEG XL, PNG, and WebP use it for
  /// sufficiently large independent phases. Lightweight or stateful formats
  /// accept a runner but encode inline when spreading work would be slower.
  Future<Uint8List> encodeWith(ParallelRunner runner, Image input) async {
    try {
      return await encodeImageWith(runner, input);
    } on ImageCodecException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException('Could not encode the ${format.name} image', cause: error);
    }
  }

  /// Encodes an image through [runner] while format-specific options apply.
  Future<Uint8List> encodeImageWith(ParallelRunner runner, Image image) => rasterEncoder.encodeWith(runner, image);
}

/// An encoder that can spread work across isolates.
base mixin ParallelRasterEncoder on RasterEncoder {
  /// Encodes [input], offering [runner] the parts that can run independently.
  ///
  /// The result is always identical to [encode]'s. Formats whose encoder has
  /// no independently encodable pieces ignore [runner] and encode inline,
  /// which keeps the entry point uniform across codecs.
  Future<Uint8List> encodeWith(ParallelRunner runner, Image input) async => encode(input);
}
