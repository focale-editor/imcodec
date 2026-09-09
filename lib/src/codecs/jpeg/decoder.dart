part of '../jpeg.dart';

/// Decodes baseline, extended sequential, and progressive Huffman JPEG data.
final class JpegDecoder extends RasterDecoder<JpegDecodeOptions> {
  /// Creates a JPEG decoder.
  const JpegDecoder();

  /// Decodes one JPEG image to opaque RGBA pixels.
  @override
  Image decodeImage(Uint8List bytes, JpegDecodeOptions options) {
    final _JpegData jpeg = _JpegData(maxPixels: options.maxPixels)..read(bytes);
    return _renderJpeg(jpeg);
  }

  /// Decodes four-component JPEG files without discarding their CMYK samples.
  DecodedImage decodeData(Uint8List bytes, {required int maxPixels}) {
    final _JpegData jpeg = _JpegData(maxPixels: maxPixels)..read(bytes);
    return jpeg.components.length == 4 ? _renderJpegCmykData(jpeg) : DecodedImage.fromImage(_renderJpeg(jpeg));
  }

  @override
  JpegDecodeOptions createDecodeOptions({
    int maxPixels = RasterDecodeOptions.defaultMaxPixels,
  }) => JpegDecodeOptions(maxPixels: maxPixels);
}

/// Options for JPEG decoding.
final class JpegDecodeOptions extends RasterDecodeOptions {
  /// Creates a JPEG decode options.
  const JpegDecodeOptions({
    super.maxPixels,
  });
}
