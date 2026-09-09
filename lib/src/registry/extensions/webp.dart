part of '../registry.dart';

/// The WebP codec extension.
final class _WebPCodecExtension extends ParallelRasterCodecExtension<WebPEncodeOptions, WebPEncoder, WebPDecodeOptions, WebPDecoder, WebPCodec> {
  /// Creates a WebP codec extension.
  const _WebPCodecExtension()
    : super(
        codec: const WebPCodec(),
      );
}
