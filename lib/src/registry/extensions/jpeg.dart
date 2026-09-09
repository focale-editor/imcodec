part of '../registry.dart';

/// The JPEG codec extension.
final class _JpegCodecExtension extends ParallelRasterCodecExtension<JpegEncodeOptions, JpegEncoder, JpegDecodeOptions, JpegDecoder, JpegCodec> {
  /// Creates a JPEG codec extension.
  const _JpegCodecExtension()
    : super(
        codec: const JpegCodec(),
      );

  @override
  DecodedImage decodeData(
    Uint8List bytes, {
    JpegDecodeOptions? decodeOptions,
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
