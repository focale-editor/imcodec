part of '../registry.dart';

/// The BMP codec extension.
final class _BmpCodecExtension extends RasterCodecExtension<BmpEncodeOptions, BmpEncoder, BmpDecodeOptions, BmpDecoder, BmpCodec> {
  /// Creates a BMP codec extension.
  const _BmpCodecExtension()
    : super(
        codec: const BmpCodec(),
      );
}
