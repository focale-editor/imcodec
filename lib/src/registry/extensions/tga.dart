part of '../registry.dart';

/// The TGA codec extension.
final class _TgaCodecExtension extends RasterCodecExtension<TgaEncodeOptions, TgaEncoder, TgaDecodeOptions, TgaDecoder, TgaCodec> {
  /// Creates a TGA codec extension.
  const _TgaCodecExtension()
    : super(
        codec: const TgaCodec(),
      );
}
