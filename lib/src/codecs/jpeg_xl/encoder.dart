part of '../jpeg_xl.dart';

/// Encodes straight-alpha RGBA images as lossless JPEG XL Modular data.
final class JpegXlEncoder extends RasterEncoder {
  /// How much candidate search the encoder performs.
  final JpegXlEffort effort;

  /// Creates a lossless JPEG XL encoder.
  const JpegXlEncoder({
    this.effort = JpegXlEffort.balanced,
  });

  @override
  Uint8List encode(Image image) => JpegXlCodestreamEncoder.encodeLossless(
    image.bytes,
    width: image.width,
    height: image.height,
    hasAlpha: true,
    effort: effort,
  );
}
