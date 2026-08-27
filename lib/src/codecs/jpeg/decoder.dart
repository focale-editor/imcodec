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
}
