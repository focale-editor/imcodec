part of '../qoi.dart';

/// Encodes and decodes Quite OK Image data.
final class QoiCodec extends RasterCodec<QoiEncodeOptions, QoiEncoder, QoiDecodeOptions, QoiDecoder> {
  /// Creates a Quite OK Image codec with a bounded decoding allocation.
  const QoiCodec({
    super.rasterEncoder = const QoiEncoder(),
    super.rasterDecoder = const QoiDecoder(),
  }) : super(
         format: ImageFormat.qoi,
       );
}
