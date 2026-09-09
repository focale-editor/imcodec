part of '../registry.dart';

/// The Quite OK Image codec extension.
final class _QoiCodecExtension extends RasterCodecExtension<QoiEncodeOptions, QoiEncoder, QoiDecodeOptions, QoiDecoder, QoiCodec> {
  /// Creates a Quite OK Image codec extension.
  const _QoiCodecExtension()
    : super(
        codec: const QoiCodec(),
      );
}
