part of '../registry.dart';

/// The PNG codec extension.
final class _PngCodecExtension extends ParallelRasterCodecExtension<PngEncodeOptions, PngEncoder, PngDecodeOptions, PngDecoder, PngCodec> {
  /// Creates a PNG codec extension.
  const _PngCodecExtension()
    : super(
        codec: const PngCodec(),
      );

  @override
  DecodedImage decodeData(
    Uint8List bytes, {
    PngDecodeOptions? decodeOptions,
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
