part of '../registry.dart';

/// The JPEG XL codec extension.
final class _JpegXlCodecExtension extends ParallelRasterCodecExtension<JpegXlEncodeOptions, JpegXlEncoder, JpegXlDecodeOptions, JpegXlDecoder, JpegXlCodec> {
  /// Creates a JPEG XL codec extension.
  const _JpegXlCodecExtension()
    : super(
        codec: const JpegXlCodec(),
      );

  @override
  DecodedImageMetadata inspect(
    Uint8List bytes, {
    int maxIccProfileBytes = defaultMaxIccProfileBytes,
    int maxDescriptiveMetadataBytes = defaultMaxDescriptiveMetadataBytes,
  }) {
    try {
      final JpegXlCodestreamInfo information = JpegXlCodestreamInfo.fromBytes(
        bytes: bytes,
      );
      return DecodedImageMetadata(
        width: information.width,
        height: information.height,
        bitsPerChannel: information.usesFloatSamples ? 32 : information.bitsPerSample,
        colorModel: DecodedColorModel.rgb,
      );
    } on ImageCodecException {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException(
        'Could not inspect the JPEG XL image',
        cause: error,
      );
    }
  }
}
