part of '../tiff.dart';

/// Encodes and decodes Tagged Image File Format images.
final class TiffCodec extends RasterCodec<TiffEncoder, TiffDecoder> {
  @override
  final TiffEncoder rasterEncoder;

  @override
  final TiffDecoder rasterDecoder;

  /// Creates a TIFF codec with a bounded decoding allocation.
  TiffCodec({
    int maxPixels = defaultMaxPixels,
    TiffCompression compression = TiffCompression.packBits,
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: TiffEncoder(compression: compression),
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const TiffCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const TiffEncoder(),
    this.rasterDecoder = const TiffDecoder(),
  }) : super(
         format: ImageFormat.tiff,
       );
}
