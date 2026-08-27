part of '../webp.dart';

/// Encodes and decodes WebP images.
/// Encoding produces lossless VP8L data. Decoding accepts lossless VP8L,
/// lossy VP8, alpha data, and the first frame of animated WebP files.
final class WebPCodec extends RasterCodec<WebPEncoder, WebPDecoder> with ParallelRasterCodec<WebPEncoder, WebPDecoder> {
  @override
  final WebPEncoder rasterEncoder;

  @override
  final WebPDecoder rasterDecoder;

  /// Creates a WebP codec with a bounded decoding allocation.
  const WebPCodec({
    int maxPixels = defaultMaxPixels,
  }) : this.customCoders(
         maxPixels: maxPixels,
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const WebPCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const WebPEncoder(),
    this.rasterDecoder = const WebPDecoder(),
  }) : super(
         format: ImageFormat.webp,
       );
}
