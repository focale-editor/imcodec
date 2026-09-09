part of '../registry.dart';

/// The GIF codec extension.
final class _GifCodecExtension extends RasterCodecExtension<GifEncodeOptions, GifEncoder, GifDecodeOptions, GifDecoder, GifCodec> {
  /// Creates a GIF codec extension.
  const _GifCodecExtension()
    : super(
        codec: const GifCodec(),
      );
}
