part of '../tga.dart';

/// Encodes and decodes Truevision TGA images.
final class TgaCodec extends RasterCodec<TgaEncodeOptions, TgaEncoder, TgaDecodeOptions, TgaDecoder> {
  /// Creates a TGA codec with a bounded decoding allocation.
  const TgaCodec({
    super.rasterEncoder = const TgaEncoder(),
    super.rasterDecoder = const TgaDecoder(),
  }) : super(
         format: ImageFormat.tga,
       );
}
