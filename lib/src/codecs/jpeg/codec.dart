part of '../jpeg.dart';

/// Encodes and decodes Joint Photographic Experts Group images synchronously.
final class JpegCodec extends RasterCodec {
  @override
  final JpegEncoder rasterEncoder;

  @override
  final JpegDecoder rasterDecoder;

  /// Creates a JPEG codec with immutable encoding and decoding options.
  JpegCodec({
    int maxPixels = defaultMaxPixels,
    int quality = 100,
    JpegChroma chroma = JpegChroma.yuv444,
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: JpegEncoder(
           quality: quality,
           chroma: chroma,
         ),
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const JpegCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const JpegEncoder(),
    this.rasterDecoder = const JpegDecoder(),
  }) : super(
         format: ImageFormat.jpeg,
       );
}
