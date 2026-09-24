part of '../jpeg.dart';

/// Decodes baseline, extended sequential, and progressive Huffman JPEG data.
final class JpegDecoder extends RasterDecoder<JpegDecodeOptions> {
  /// Creates a JPEG decoder.
  const JpegDecoder({
    JpegDecodeOptions defaultOptions = const JpegDecodeOptions(),
  }) : super(
         defaultDecodeOptions: defaultOptions,
       );

  /// Decodes one JPEG image to opaque RGBA pixels.
  @override
  Image decodeWithOptions(Uint8List bytes, JpegDecodeOptions options) {
    final _JpegData jpeg = _JpegData(maxPixels: options.maxPixels)..read(bytes);
    return _renderJpeg(jpeg);
  }

  /// Decodes four-component JPEG files without discarding their CMYK samples.
  DecodedImage decodeData(Uint8List bytes, {required int maxPixels}) {
    final _JpegData jpeg = _JpegData(maxPixels: maxPixels)..read(bytes);
    return jpeg.components.length == 4 ? _renderJpegCmykData(jpeg) : DecodedImage.fromImage(_renderJpeg(jpeg));
  }
}

/// Options for JPEG decoding.
final class JpegDecodeOptions extends RasterDecodeOptions {
  /// Creates a JPEG decode options.
  const JpegDecodeOptions({
    super.maxPixels,
  });
}
