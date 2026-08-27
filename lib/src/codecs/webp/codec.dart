part of '../webp.dart';

/// Encodes and decodes WebP images.
/// Encoding produces lossless VP8L or lossy VP8 data. Decoding accepts
/// lossless VP8L, lossy VP8, alpha data, and the first frame of animated WebP
/// files.
final class WebPCodec extends RasterCodec<WebPEncoder, WebPDecoder> with ParallelRasterCodec<WebPEncoder, WebPDecoder> {
  @override
  final WebPEncoder rasterEncoder;

  @override
  final WebPDecoder rasterDecoder;

  /// Creates a WebP codec with a bounded decoding allocation.
  ///
  /// Encoding stays lossless when [quality] is omitted. Supplying a quality
  /// selects lossy VP8 encoding; values outside zero through 100 are clamped.
  WebPCodec({
    int maxPixels = defaultMaxPixels,
    int? quality,
    WebPEffort effort = WebPEffort.balanced,
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: WebPEncoder(
           quality: quality,
           effort: effort,
         ),
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
