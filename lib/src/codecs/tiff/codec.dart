part of '../tiff.dart';

/// Encodes and decodes Tagged Image File Format images.
final class TiffCodec extends RasterCodec<TiffEncodeOptions, TiffEncoder, TiffDecodeOptions, TiffDecoder> {
  /// Creates a TIFF codec with a bounded decoding allocation.
  const TiffCodec({
    super.rasterEncoder = const TiffEncoder(),
    super.rasterDecoder = const TiffDecoder(),
  }) : super(
         format: ImageFormat.tiff,
       );
}
