part of '../png.dart';

/// Encodes and decodes Portable Network Graphics images.
final class PngCodec extends RasterCodec<PngEncoder, PngDecoder> with ParallelRasterCodec<PngEncoder, PngDecoder> {
  @override
  final PngEncoder rasterEncoder;

  @override
  final PngDecoder rasterDecoder;

  /// Creates a codec using a zlib [level] from 0 through 9.
  PngCodec({
    int maxPixels = defaultMaxPixels,
    int level = 6,
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: PngEncoder(level: level),
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const PngCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const PngEncoder(),
    this.rasterDecoder = const PngDecoder(),
  }) : super(
         format: ImageFormat.png,
       );
}
