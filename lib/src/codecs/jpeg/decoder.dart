part of '../jpeg.dart';

/// Decodes baseline, extended sequential, and progressive Huffman JPEG data.
final class JpegDecoder extends RasterDecoder {
  /// Creates a JPEG decoder.
  const JpegDecoder();

  /// Decodes one JPEG image to opaque RGBA pixels.
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    final _JpegData jpeg = _JpegData(maxPixels: maxPixels)..read(bytes);
    return _renderJpeg(jpeg);
  }

  /// Decodes four-component JPEG files without discarding their CMYK samples.
  DecodedImage decodeData(Uint8List bytes, {required int maxPixels}) {
    final _JpegData jpeg = _JpegData(maxPixels: maxPixels)..read(bytes);
    return jpeg.components.length == 4 ? _renderJpegCmykData(jpeg) : DecodedImage.fromImage(_renderJpeg(jpeg));
  }
}
