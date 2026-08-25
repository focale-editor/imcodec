import 'dart:typed_data';

import 'package:imcodec/src/codecs/bmp_codec.dart';
import 'package:imcodec/src/codecs/jpeg_encoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl_codec.dart';
import 'package:imcodec/src/codecs/png_encoder.dart';
import 'package:imcodec/src/codecs/qoi_codec.dart';
import 'package:imcodec/src/codecs/tga_codec.dart';
import 'package:imcodec/src/codecs/tiff_codec.dart';
import 'package:imcodec/src/codecs/webp_encoder.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';

/// Encodes [image] to [format].
///
/// [quality] only affects JPEG output. [pngLevel] is the zlib compression
/// level and ranges from 0 through 9.
Uint8List encodeImage(Image image, {required ImageFormat format, int quality = 90, int pngLevel = 6}) => switch (format) {
  ImageFormat.bmp => encodeBmp(image),
  ImageFormat.jpeg => encodeJpg(image, quality: quality),
  ImageFormat.jpegXl => encodeJpegXl(image),
  ImageFormat.png => encodePng(image, level: pngLevel),
  ImageFormat.qoi => encodeQoi(image),
  ImageFormat.tga => encodeTga(image),
  ImageFormat.tiff => encodeTiff(image),
  ImageFormat.webp => encodeWebP(image),
};

/// Encodes [image] as a 32-bit BMP with alpha bitfields.
Uint8List encodeBmp(Image image) => const BmpEncoder().encode(image);

/// Encodes [image] as lossless JPEG XL Modular data.
Uint8List encodeJpegXl(Image image) => const JpegXlEncoder().encode(image);

/// Encodes [image] as lossless JPEG XL Modular data.
Uint8List encodeJxl(Image image) => encodeJpegXl(image);

/// Encodes [image] as an 8-bit RGBA PNG.
Uint8List encodePng(Image image, {int level = 6}) => PngEncoder(level: level).encode(image);

/// Encodes [image] as a lossless Quite OK Image.
Uint8List encodeQoi(Image image) => const QoiEncoder().encode(image);

/// Encodes [image] as a 32-bit TGA image.
///
/// Run-length encoding is enabled by default and can be disabled for consumers
/// that only support uncompressed true-color TGA files.
Uint8List encodeTga(Image image, {bool runLengthEncoding = true}) => const TgaEncoder().encode(image, runLengthEncoding: runLengthEncoding);

/// Encodes [image] as an eight-bit RGBA TIFF image.
Uint8List encodeTiff(Image image, {TiffCompression compression = TiffCompression.packBits}) => const TiffEncoder().encode(image, compression: compression);

/// Encodes [image] as a baseline JPEG.
///
/// Transparent pixels are composited against white because JPEG has no alpha
/// channel. [quality] is clamped to the range 1 through 100.
Uint8List encodeJpg(Image image, {int quality = 100, JpegChroma chroma = JpegChroma.yuv444}) {
  if (image.width > 65535 || image.height > 65535) {
    throw const ImageCodecException('JPEG dimensions may not exceed 65535 pixels');
  }
  return JpegEncoder(quality: quality).encode(image, chroma: chroma);
}

/// Encodes [image] as a baseline JPEG.
Uint8List encodeJpeg(Image image, {int quality = 100, JpegChroma chroma = JpegChroma.yuv444}) => encodeJpg(image, quality: quality, chroma: chroma);

/// Encodes [image] as a lossless VP8L WebP image.
Uint8List encodeWebP(Image image) {
  if (image.width > 16384 || image.height > 16384) {
    throw const ImageCodecException('Lossless WebP dimensions may not exceed 16384 pixels');
  }
  return const WebPEncoder().encode(image);
}
