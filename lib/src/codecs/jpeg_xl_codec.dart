import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl.dart' as jpeg_xl;
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';

/// Encodes straight RGBA pixels as lossless JPEG XL Modular data.
final class JpegXlEncoder {
  /// Creates a lossless JPEG XL encoder.
  const JpegXlEncoder();

  /// Encodes [image] as a bare, standards-compliant JPEG XL codestream.
  Uint8List encode(Image image) {
    try {
      return jpeg_xl.JpegXlCodestreamEncoder.encodeLossless(
        image.bytes,
        width: image.width,
        height: image.height,
        hasAlpha: true,
      );
    } on Object catch (error) {
      throw ImageCodecException('Could not encode the JPEG XL image', cause: error);
    }
  }
}

/// Decodes JPEG XL codestreams and containers to straight RGBA pixels.
final class JpegXlDecoder {
  /// Creates a JPEG XL decoder.
  const JpegXlDecoder();

  /// Decodes the first visible frame in [bytes].
  Image decode(Uint8List bytes, {required int maxPixels}) {
    if (maxPixels < 1) {
      throw RangeError.range(maxPixels, 1, null, 'maxPixels');
    }
    try {
      final jpeg_xl.JpegXlCodestreamInfo information = jpeg_xl.JpegXlCodestreamInfo.fromBytes(bytes: bytes);
      final int pixelCount = information.width * information.height;
      if (pixelCount > maxPixels) {
        throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
      }
      final jpeg_xl.JpegXlDecodedImage decoded = jpeg_xl.JpegXlCodestreamDecoder.decode(bytes);
      return Image.fromRgba(
        width: decoded.width,
        height: decoded.height,
        bytes: decoded.toRgba8(),
        copy: false,
      );
    } on ImageCodecException {
      rethrow;
    } on Object catch (error) {
      throw ImageCodecException('Could not decode the JPEG XL image', cause: error);
    }
  }
}
