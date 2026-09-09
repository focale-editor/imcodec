import 'dart:convert';
import 'dart:typed_data';

import 'package:imcodec/src/codecs/exception.dart';
import 'package:imcodec/src/formats/image_format.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/parallel_runner.dart';

/// Allows to pass options to a [RasterDecoder].
class RasterDecodeOptions {
  /// Default maximum number of pixels accepted by raster decoders.
  static const int defaultMaxPixels = 100000000;

  /// Maximum number of pixels to decode.
  final int maxPixels;

  /// Creates a decode options.
  const RasterDecodeOptions({
    this.maxPixels = defaultMaxPixels,
  });
}

/// Allows to pass options to a [RasterEncoder].
class RasterEncodeOptions {
  /// Creates an encode options.
  const RasterEncodeOptions();
}

/// Converts encoded raster bytes to an [Image].
abstract base class RasterDecoder<Options extends RasterDecodeOptions> extends Converter<Uint8List, Image> {
  /// Creates a raster decoder.
  const RasterDecoder();

  /// Decodes [input] to an image.
  Image decode(Uint8List input, {Options? decodeOptions}) => decodeImage(input, decodeOptions ?? createDefaultDecodeOptions());

  /// Decodes [input] to an image, with the given options or default options.
  Image decodeImage(Uint8List input, Options options);

  @override
  Image convert(Uint8List input, {Options? decodeOptions}) => decode(input, decodeOptions: decodeOptions);

  /// Creates decode options with a format-independent pixel limit.
  Options createDecodeOptions({
    int maxPixels = RasterDecodeOptions.defaultMaxPixels,
  });

  /// Creates the default decode options.
  Options createDefaultDecodeOptions() => createDecodeOptions();
}

/// Converts an [Image] to encoded raster bytes.
abstract base class RasterEncoder<Options extends RasterEncodeOptions> extends Converter<Image, Uint8List> {
  /// Creates a raster encoder.
  const RasterEncoder();

  /// Encodes [input] to raster bytes.
  Uint8List encode(Image input, {Options? encodeOptions}) => encodeImage(input, encodeOptions ?? createDefaultEncodeOptions());

  /// Encodes [input] to raster bytes, with the given options or default options.
  Uint8List encodeImage(Image input, Options encodeOptions);

  @override
  Uint8List convert(Image input, {Options? encodeOptions}) => encode(
    input,
    encodeOptions: encodeOptions,
  );

  /// Creates a default encode options.
  Options createDefaultEncodeOptions();
}

/// Provides shared validation and error handling for synchronous image codecs.
abstract base class RasterCodec<
  EncodeOptions extends RasterEncodeOptions,
  Encoder extends RasterEncoder<EncodeOptions>,
  DecodeOptions extends RasterDecodeOptions,
  Decoder extends RasterDecoder<DecodeOptions>
>
    extends Codec<Image, Uint8List> {
  /// Format accepted and produced by this codec.
  final ImageFormat format;

  /// Encoder configured with this codec's output options.
  final Encoder rasterEncoder;

  /// Decoder used after shared input validation.
  final Decoder rasterDecoder;

  /// Creates a codec for [format] with a bounded decoding allocation.
  const RasterCodec({
    required this.format,
    required this.rasterEncoder,
    required this.rasterDecoder,
  });

  /// Recognizes input accepted by this codec before attempting a decode.
  ///
  /// This uses the format's own matcher and does not require global registry
  /// installation, so directly constructed add-on codecs remain independent.
  bool acceptsInput(Uint8List encoded) => format.matches(encoded);

  @override
  Encoder get encoder => rasterEncoder;

  @override
  Converter<Uint8List, Image> get decoder => _RasterCodecConverter(codec: this);

  @override
  Image decode(Uint8List encoded, {DecodeOptions? decodeOptions}) {
    final DecodeOptions options = decodeOptions ?? rasterDecoder.createDefaultDecodeOptions();
    if (options.maxPixels < 1) {
      throw RangeError.range(options.maxPixels, 1, null, 'maxPixels');
    }
    if (!acceptsInput(encoded)) {
      final ImageFormat? actualFormat = ImageFormat.sniff(encoded);
      throw ImageCodecException('Expected ${format.name} data, found ${actualFormat?.name ?? 'an unknown format'}');
    }
    try {
      return decodeBytes(encoded, decodeOptions: options);
    } on ImageCodecException {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException('Could not decode the ${format.name} image', cause: error);
    }
  }

  @override
  Uint8List encode(Image input, {EncodeOptions? encodeOptions}) {
    try {
      final EncodeOptions options = encodeOptions ?? rasterEncoder.createDefaultEncodeOptions();
      return encodeImage(input, encodeOptions: options);
    } on ImageCodecException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException('Could not encode the ${format.name} image', cause: error);
    }
  }

  /// Decodes bytes after shared format and allocation-option validation.
  Image decodeBytes(Uint8List encoded, {DecodeOptions? decodeOptions}) => rasterDecoder.decode(encoded, decodeOptions: decodeOptions);

  /// Encodes an image while format-specific options are in effect.
  Uint8List encodeImage(Image image, {EncodeOptions? encodeOptions}) => rasterEncoder.encode(image, encodeOptions: encodeOptions);

  /// Rejects dimensions that exceed [maxPixels] before allocating pixels.
  void checkDecodedDimensions(int width, int height, int maxPixels) {
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
base mixin ParallelRasterCodec<
  EncodeOptions extends RasterEncodeOptions,
  Encoder extends ParallelRasterEncoder<EncodeOptions>,
  DecodeOptions extends RasterDecodeOptions,
  Decoder extends RasterDecoder<DecodeOptions>
>
    on RasterCodec<EncodeOptions, Encoder, DecodeOptions, Decoder> {
  /// Encodes [input], offering [runner] the parts that can run independently.
  ///
  /// The bytes match [encode]'s exactly, so passing a runner can only make
  /// encoding faster, never different. JPEG, JPEG XL, PNG, and WebP use it for
  /// sufficiently large independent phases. Lightweight or stateful formats
  /// accept a runner but encode inline when spreading work would be slower.
  Future<Uint8List> encodeWith(ParallelRunner runner, Image input, {EncodeOptions? encodeOptions}) async {
    try {
      return await encodeImageWith(runner, input, encodeOptions: encodeOptions);
    } on ImageCodecException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException('Could not encode the ${format.name} image', cause: error);
    }
  }

  /// Encodes an image through [runner] while format-specific options apply.
  Future<Uint8List> encodeImageWith(
    ParallelRunner runner,
    Image image, {
    EncodeOptions? encodeOptions,
  }) => rasterEncoder.encodeWith(
    runner,
    image,
    encodeOptions: encodeOptions,
  );
}

/// An encoder that can spread work across isolates.
base mixin ParallelRasterEncoder<Options extends RasterEncodeOptions> on RasterEncoder<Options> {
  /// Encodes [input], offering [runner] the parts that can run independently.
  ///
  /// The result is always identical to [encode]'s. Formats whose encoder has
  /// no independently encodable pieces ignore [runner] and encode inline,
  /// which keeps the entry point uniform across codecs.
  Future<Uint8List> encodeWith(
    ParallelRunner runner,
    Image input, {
    Options? encodeOptions,
  }) => encodeImageWith(
    runner,
    input,
    encodeOptions ?? createDefaultEncodeOptions(),
  );

  /// Encodes [input], offering [runner] the parts that can run independently.
  ///
  /// The result is always identical to [encode]'s. Formats whose encoder has
  /// no independently encodable pieces ignore [runner] and encode inline,
  /// which keeps the entry point uniform across codecs.
  Future<Uint8List> encodeImageWith(
    ParallelRunner runner,
    Image input,
    Options options,
  ) async => encode(
    input,
    encodeOptions: options,
  );
}
