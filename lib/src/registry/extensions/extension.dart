part of '../registry.dart';

/// Supplies an optional codec implementation without adding a package dependency.
///
/// Implementations register once in each isolate through [ImageCodecRegistry].
/// A new format is registered separately through [ImageFormatRegistry], which
/// keeps signature discovery independent from codec implementation.
abstract base class ImageCodecExtension<EncodeOptions extends RasterEncodeOptions, DecodeOptions extends RasterDecodeOptions> {
  /// Creates an immutable format extension.
  const ImageCodecExtension();

  /// Format implemented by this extension.
  ImageFormat get format;

  /// Decodes straight RGBA8 using format-specific [decodeOptions].
  ///
  /// Implementations must reject a non-positive or exceeded pixel limit from
  /// [decodeOptions] before allocating their output, and use their default
  /// options when it is omitted.
  Image decode(
    Uint8List bytes, {
    DecodeOptions? decodeOptions,
  }) => throw ImageCodecException('This extension does not decode ${format.name}');

  /// Decodes native process samples without reducing their precision.
  ///
  /// The default implementation wraps the extension's RGBA8 decode. Codecs
  /// that retain wider or non-RGB process samples override this method and
  /// must enforce [maxDecodedBytes] before allocating their output whenever
  /// the encoded dimensions are available in advance.
  DecodedImage decodeData(
    Uint8List bytes, {
    DecodeOptions? decodeOptions,
    required int maxDecodedBytes,
    required int maxIccProfileBytes,
  }) => _checkDecodedByteLength(
    DecodedImage.fromImage(
      decode(
        bytes,
        decodeOptions: decodeOptions,
      ),
    ),
    maxDecodedBytes,
  );

  /// Encodes straight RGBA8 with the extension's default compression options.
  Uint8List encode(Image image, {EncodeOptions? encodeOptions});

  /// Inspects container metadata without decoding pixels.
  DecodedImageMetadata? inspect(
    Uint8List bytes, {
    int maxIccProfileBytes = defaultMaxIccProfileBytes,
    int maxDescriptiveMetadataBytes = defaultMaxDescriptiveMetadataBytes,
  }) => null;
}

/// A codec extension that offers independent encoding work.
base mixin ParallelImageCodecExtension<EncodeOptions extends RasterEncodeOptions, DecodeOptions extends RasterDecodeOptions> on ImageCodecExtension<EncodeOptions, DecodeOptions> {
  /// Offers independent encoding work to [runner], returning identical bytes.
  ///
  /// The default implementation encodes inline. Extensions with transferable
  /// work may override this without requiring registration in worker isolates.
  Future<Uint8List> encodeWith(ParallelRunner runner, Image image, {EncodeOptions? encodeOptions}) async => encode(
    image,
    encodeOptions: encodeOptions,
  );
}

/// A codec extension for a [RasterCodec].
final class RasterCodecExtension<
  EncodeOptions extends RasterEncodeOptions,
  Encoder extends RasterEncoder<EncodeOptions>,
  DecodeOptions extends RasterDecodeOptions,
  Decoder extends RasterDecoder<DecodeOptions>,
  Codec extends RasterCodec<EncodeOptions, Encoder, DecodeOptions, Decoder>
>
    extends ImageCodecExtension<EncodeOptions, DecodeOptions> {
  /// Codec used in this extension.
  final Codec _codec;

  /// Creates a codec extension for [_codec].
  const RasterCodecExtension({
    required this._codec,
  });

  @override
  ImageFormat get format => _codec.format;

  @override
  Image decode(
    Uint8List bytes, {
    DecodeOptions? decodeOptions,
  }) => _codec.decode(
    bytes,
    decodeOptions: decodeOptions,
  );

  @override
  Uint8List encode(
    Image image, {
    EncodeOptions? encodeOptions,
  }) => _codec.encode(
    image,
    encodeOptions: encodeOptions,
  );
}

/// A codec extension for a [ParallelRasterCodec].
final class ParallelRasterCodecExtension<
  EncodeOptions extends RasterEncodeOptions,
  Encoder extends ParallelRasterEncoder<EncodeOptions>,
  DecodeOptions extends RasterDecodeOptions,
  Decoder extends RasterDecoder<DecodeOptions>,
  Codec extends ParallelRasterCodec<EncodeOptions, Encoder, DecodeOptions, Decoder>
>
    extends RasterCodecExtension<EncodeOptions, Encoder, DecodeOptions, Decoder, Codec>
    with ParallelImageCodecExtension<EncodeOptions, DecodeOptions> {
  /// Creates a parallel codec extension for [_codec].
  const ParallelRasterCodecExtension({
    required super.codec,
  });

  @override
  Future<Uint8List> encodeWith(
    ParallelRunner runner,
    Image image, {
    EncodeOptions? encodeOptions,
  }) => (_codec as ParallelRasterCodec).encodeWith(
    runner,
    image,
    encodeOptions: encodeOptions,
  );
}

/// Enforces a decoded-sample allocation limit for extension implementations.
DecodedImage _checkDecodedByteLength(
  DecodedImage decoded,
  int maxDecodedBytes,
) {
  if (maxDecodedBytes < 1) {
    throw RangeError.range(
      maxDecodedBytes,
      1,
      null,
      'maxDecodedBytes',
    );
  }
  if (decoded.bytes.lengthInBytes > maxDecodedBytes) {
    throw ImageCodecException(
      'Decoded samples need ${decoded.bytes.lengthInBytes} bytes, exceeding the $maxDecodedBytes byte limit',
    );
  }
  return decoded;
}
