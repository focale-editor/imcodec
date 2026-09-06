part of '../open_exr.dart';

/// Compression methods emitted by [OpenExrEncoder].
enum OpenExrCompression {
  /// Stores one scan line per block without compression.
  none(value: 0, linesPerBlock: 1),

  /// Applies zlib compression independently to every scan line.
  zips(value: 2, linesPerBlock: 1),

  /// Applies zlib compression to groups of up to sixteen scan lines.
  zip(value: 3, linesPerBlock: 16);

  /// Value stored in the OpenEXR `compression` attribute.
  final int value;

  /// Number of consecutive scan lines stored by one encoded block.
  final int linesPerBlock;

  /// Creates one OpenEXR compression choice.
  const OpenExrCompression({
    required this.value,
    required this.linesPerBlock,
  });
}

/// Encodes and decodes ordinary single-part OpenEXR scan-line images.
final class OpenExrCodec extends RasterCodec<OpenExrEncoder, OpenExrDecoder> {
  @override
  final OpenExrEncoder rasterEncoder;

  @override
  final OpenExrDecoder rasterDecoder;

  /// Creates a codec with bounded decoding and lossless ZIP output.
  OpenExrCodec({
    int maxPixels = defaultMaxPixels,
    OpenExrCompression compression = OpenExrCompression.zip,
  }) : this.customCoders(
         maxPixels: maxPixels,
         rasterEncoder: OpenExrEncoder(compression: compression),
       );

  /// Creates a codec with independently supplied encoder and decoder.
  const OpenExrCodec.customCoders({
    super.maxPixels = defaultMaxPixels,
    this.rasterEncoder = const OpenExrEncoder(),
    this.rasterDecoder = const OpenExrDecoder(),
  }) : super(format: ImageFormat.openExr);
}
