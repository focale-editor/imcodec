part of '../jbig2.dart';

/// Encodes and decodes standalone JBIG2 black-and-white images.
///
/// PDF streams have no signature and use [Jbig2Decoder.decodeEmbedded] and
/// [Jbig2Encoder.encodeEmbedded] explicitly.
final class Jbig2Codec extends RasterCodec<Jbig2EncodeOptions, Jbig2Encoder, Jbig2DecodeOptions, Jbig2Decoder> {
  /// Creates a JBIG2 codec with configurable encoder and decoder defaults.
  const Jbig2Codec({super.rasterEncoder = const Jbig2Encoder(), super.rasterDecoder = const Jbig2Decoder()}) : super(format: ImageFormat.jbig2);
}
