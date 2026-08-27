part of '../jpeg_xl.dart';

/// Encodes and decodes JPEG XL images synchronously.
final class JpegXlCodec extends RasterCodec {
  @override
  final JpegXlEncoder rasterEncoder;

  @override
  final JpegXlDecoder rasterDecoder;

  /// Creates a JPEG XL codec with a bounded decoding allocation.
  const JpegXlCodec({
    int maxPixels = defaultMaxPixels,
  }) : this.customCoders(
         maxPixels: maxPixels,
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
