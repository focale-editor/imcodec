part of '../open_exr.dart';

/// Encodes and decodes ordinary single-part OpenEXR scan-line images.
final class OpenExrCodec extends RasterCodec<OpenExrEncodeOptions, OpenExrEncoder, OpenExrDecodeOptions, OpenExrDecoder> {
  /// Creates a codec with bounded decoding and lossless ZIP output.
  const OpenExrCodec({
    super.rasterEncoder = const OpenExrEncoder(),
    super.rasterDecoder = const OpenExrDecoder(),
  }) : super(
         format: ImageFormat.openExr,
       );
}
