part of '../registry.dart';

/// The JBIG2 codec extension.
final class _Jbig2CodecExtension extends RasterCodecExtension<Jbig2EncodeOptions, Jbig2Encoder, Jbig2DecodeOptions, Jbig2Decoder, Jbig2Codec> {
  /// Creates a JBIG2 codec extension.
  const _Jbig2CodecExtension()
    : super(
        codec: const Jbig2Codec(),
      );
  @override
  DecodedImage decodeData(Uint8List bytes, {Jbig2DecodeOptions? decodeOptions, required int maxDecodedBytes, required int maxIccProfileBytes}) {
    final Jbig2DecodeOptions options = decodeOptions ?? const Jbig2DecodeOptions();
    if (maxDecodedBytes < 4) {
      throw const ImageCodecException('JBIG2 decoded byte budget cannot hold one pixel');
    }
    return DecodedImage.fromImage(
      decode(
        bytes,
        decodeOptions: Jbig2DecodeOptions(
          page: options.page,
          maxPixels: options.maxPixels < maxDecodedBytes ~/ 4 ? options.maxPixels : maxDecodedBytes ~/ 4,
          maxWorkingBytes: options.maxWorkingBytes,
          maxSegments: options.maxSegments,
        ),
      ),
    );
  }
}
