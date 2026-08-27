part of '../jpeg_xl.dart';

/// Encodes and decodes JPEG XL images.
final class JpegXlCodec extends RasterCodec<JpegXlEncoder, JpegXlDecoder> with ParallelRasterCodec<JpegXlEncoder, JpegXlDecoder> {
  @override
  final JpegXlEncoder rasterEncoder;

  @override
  final JpegXlDecoder rasterDecoder;

  /// Creates a JPEG XL codec with a bounded decoding allocation.
  JpegXlCodec({
    int maxPixels = defaultMaxPixels,
    JpegXlEffort effort = JpegXlEffort.balanced,
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: JpegXlEncoder(effort: effort),
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const JpegXlCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const JpegXlEncoder(),
    this.rasterDecoder = const JpegXlDecoder(),
  }) : super(
         format: ImageFormat.jpegXl,
       );
}
