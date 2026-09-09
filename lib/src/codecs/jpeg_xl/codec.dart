part of '../jpeg_xl.dart';

/// Encodes and decodes JPEG XL images.
final class JpegXlCodec extends RasterCodec<JpegXlEncodeOptions, JpegXlEncoder, JpegXlDecodeOptions, JpegXlDecoder>
    with ParallelRasterCodec<JpegXlEncodeOptions, JpegXlEncoder, JpegXlDecodeOptions, JpegXlDecoder> {
  /// Creates a JPEG XL codec with a bounded decoding allocation.
  const JpegXlCodec({
    super.rasterEncoder = const JpegXlEncoder(),
    super.rasterDecoder = const JpegXlDecoder(),
  }) : super(
         format: ImageFormat.jpegXl,
       );
}
