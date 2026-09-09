part of '../png.dart';

/// Encodes and decodes Portable Network Graphics images.
final class PngCodec extends RasterCodec<PngEncodeOptions, PngEncoder, PngDecodeOptions, PngDecoder> with ParallelRasterCodec<PngEncodeOptions, PngEncoder, PngDecodeOptions, PngDecoder> {
  /// Creates a codec using a zlib [level] from 0 through 9.
  const PngCodec({
    super.rasterEncoder = const PngEncoder(),
    super.rasterDecoder = const PngDecoder(),
  }) : super(
         format: ImageFormat.png,
       );
}
