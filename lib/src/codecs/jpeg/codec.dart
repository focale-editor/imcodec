part of '../jpeg.dart';

/// Encodes and decodes Joint Photographic Experts Group images.
final class JpegCodec extends RasterCodec<JpegEncodeOptions, JpegEncoder, JpegDecodeOptions, JpegDecoder> with ParallelRasterCodec<JpegEncodeOptions, JpegEncoder, JpegDecodeOptions, JpegDecoder> {
  /// Creates a JPEG codec with immutable encoding and decoding options.
  const JpegCodec({
    super.rasterEncoder = const JpegEncoder(),
    super.rasterDecoder = const JpegDecoder(),
  }) : super(
         format: ImageFormat.jpeg,
       );
}
