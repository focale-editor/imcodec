part of '../jpeg_xl.dart';

/// Encodes straight-alpha RGBA images as lossless JPEG XL Modular data.
final class JpegXlEncoder extends RasterEncoder with ParallelRasterEncoder {
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

  @override
  Future<Uint8List> encodeWith(ParallelRunner runner, Image input) => JpegXlCodestreamEncoder.encodeLosslessWith(
    runner,
    input.bytes,
    width: input.width,
    height: input.height,
    hasAlpha: true,
    effort: effort,
  );
}
