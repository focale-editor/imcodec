part of '../gif.dart';

/// Encodes and decodes the first image in Graphics Interchange Format data.
final class GifCodec extends RasterCodec<GifEncoder, GifDecoder> {
  @override
  final GifEncoder rasterEncoder;

  @override
  final GifDecoder rasterDecoder;

  /// Creates a static GIF codec using [options] for palette reduction.
  GifCodec({
    int maxPixels = defaultMaxPixels,
    IndexedColorOptions options = const IndexedColorOptions(),
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: GifEncoder(options: options),
       );

  /// Creates a codec from independently configured coders.
  const GifCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const GifEncoder(),
    this.rasterDecoder = const GifDecoder(),
  }) : super(format: ImageFormat.gif);
}
