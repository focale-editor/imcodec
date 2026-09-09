part of '../webp.dart';

/// Encodes and decodes WebP images.
/// Encoding produces lossless VP8L or lossy VP8 data. Decoding accepts
/// lossless VP8L, lossy VP8, alpha data, and the first frame of animated WebP
/// files.
final class WebPCodec extends RasterCodec<WebPEncodeOptions, WebPEncoder, WebPDecodeOptions, WebPDecoder> with ParallelRasterCodec<WebPEncodeOptions, WebPEncoder, WebPDecodeOptions, WebPDecoder> {
  /// Creates a WebP codec with a bounded decoding allocation.
  ///
  /// Encoding stays lossless when [quality] is omitted. Supplying a quality
  /// selects lossy VP8 encoding; values outside zero through 100 are clamped.
  const WebPCodec({
    super.rasterEncoder = const WebPEncoder(),
    super.rasterDecoder = const WebPDecoder(),
  }) : super(
         format: ImageFormat.webp,
       );
}
