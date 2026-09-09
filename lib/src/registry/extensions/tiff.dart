part of '../registry.dart';

/// The TIFF codec extension.
final class _TiffCodecExtension extends RasterCodecExtension<TiffEncodeOptions, TiffEncoder, TiffDecodeOptions, TiffDecoder, TiffCodec> {
  /// Creates a TIFF codec extension.
  const _TiffCodecExtension()
    : super(
        codec: const TiffCodec(),
      );

  @override
  DecodedImage decodeData(
    Uint8List bytes, {
    TiffDecodeOptions? decodeOptions,
    required int maxDecodedBytes,
    required int maxIccProfileBytes,
  }) => _checkDecodedByteLength(
    _codec.rasterDecoder.decodeData(
      bytes,
      maxPixels: (decodeOptions ?? _codec.rasterDecoder.createDefaultDecodeOptions()).maxPixels,
    ),
    maxDecodedBytes,
  );
}
