part of '../qoi.dart';

/// Encodes and decodes Quite OK Image data synchronously.
final class QoiCodec extends RasterCodec {
  @override
  final QoiEncoder rasterEncoder;

  @override
  final QoiDecoder rasterDecoder;

  /// Creates a Quite OK Image codec with a bounded decoding allocation.
  const QoiCodec({
    int maxPixels = defaultMaxPixels,
  }) : this.customCoders(
         maxPixels: maxPixels,
       );

  /// Creates a codec using a [rasterEncoder] to encode and a custom [rasterDecoder] to decode.
  const QoiCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const QoiEncoder(),
    this.rasterDecoder = const QoiDecoder(),
  }) : super(
         format: ImageFormat.qoi,
       );
}
