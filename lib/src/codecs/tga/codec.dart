part of '../tga.dart';

/// Encodes and decodes Truevision TGA images.
final class TgaCodec extends RasterCodec<TgaEncoder, TgaDecoder> {
  @override
  final TgaEncoder rasterEncoder;

  @override
  final TgaDecoder rasterDecoder;

  /// Creates a TGA codec with a bounded decoding allocation.
  TgaCodec({
    int maxPixels = defaultMaxPixels,
    bool runLengthEncoding = true,
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: TgaEncoder(runLengthEncoding: runLengthEncoding),
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const TgaCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const TgaEncoder(),
    this.rasterDecoder = const TgaDecoder(),
  }) : super(
         format: ImageFormat.tga,
       );
}
