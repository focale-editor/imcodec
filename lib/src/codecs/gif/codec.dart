part of '../gif.dart';

/// Encodes and decodes the first image in Graphics Interchange Format data.
final class GifCodec extends RasterCodec<GifEncodeOptions, GifEncoder, GifDecodeOptions, GifDecoder> {
  /// Creates a static GIF codec using [options] for palette reduction.
  const GifCodec({
    super.rasterEncoder = const GifEncoder(),
    super.rasterDecoder = const GifDecoder(),
  }) : super(
         format: ImageFormat.gif,
       );
}
