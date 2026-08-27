part of '../bmp.dart';

/// Encodes and decodes Bitmap images synchronously.
final class BmpCodec extends RasterCodec {
  @override
  final BmpEncoder rasterEncoder;

  @override
  final BmpDecoder rasterDecoder;

  /// Creates a Bitmap codec with a bounded decoding allocation.
  const BmpCodec({
    int maxPixels = defaultMaxPixels,
  }) : this.customCoders(
         maxPixels: maxPixels,
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const BmpCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const BmpEncoder(),
    this.rasterDecoder = const BmpDecoder(),
  }) : super(
         format: ImageFormat.bmp,
       );
}
