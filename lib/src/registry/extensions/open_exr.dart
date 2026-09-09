part of '../registry.dart';

/// The OpenEXR codec extension.
final class _OpenExrCodecExtension extends RasterCodecExtension<OpenExrEncodeOptions, OpenExrEncoder, OpenExrDecodeOptions, OpenExrDecoder, OpenExrCodec> {
  /// Creates an OpenEXR codec extension.
  const _OpenExrCodecExtension()
    : super(
        codec: const OpenExrCodec(),
      );

  @override
  DecodedImage decodeData(
    Uint8List bytes, {
    OpenExrDecodeOptions? decodeOptions,
    required int maxDecodedBytes,
    required int maxIccProfileBytes,
  }) => _codec.rasterDecoder.decodeData(
    bytes,
    maxPixels: (decodeOptions ?? _codec.rasterDecoder.createDefaultDecodeOptions()).maxPixels,
    maxDecodedBytes: maxDecodedBytes,
  );

  @override
  DecodedImageMetadata inspect(
    Uint8List bytes, {
    int maxIccProfileBytes = defaultMaxIccProfileBytes,
    int maxDescriptiveMetadataBytes = defaultMaxDescriptiveMetadataBytes,
  }) => inspectOpenExr(bytes);
}
