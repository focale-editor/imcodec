part of '../bmp.dart';

/// Encodes and decodes Bitmap images.
final class BmpCodec extends RasterCodec<BmpEncodeOptions, BmpEncoder, BmpDecodeOptions, BmpDecoder> {
  /// Creates a Bitmap codec with a bounded decoding allocation.
  const BmpCodec({
    super.rasterEncoder = const BmpEncoder(),
    super.rasterDecoder = const BmpDecoder(),
  }) : super(
         format: ImageFormat.bmp,
       );
}
