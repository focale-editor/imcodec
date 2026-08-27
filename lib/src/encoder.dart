import 'dart:typed_data';

import 'package:imcodec/src/codecs/bmp.dart';
import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl.dart';
import 'package:imcodec/src/codecs/png.dart';
import 'package:imcodec/src/codecs/qoi.dart';
import 'package:imcodec/src/codecs/tga.dart';
import 'package:imcodec/src/codecs/tiff.dart';
import 'package:imcodec/src/codecs/webp.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_format.dart';

/// Encodes [image] to [format].
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
Uint8List encodeBmp(Image image) => const BmpCodec().encode(image);

/// Encodes [image] as lossless JPEG XL Modular data.
Uint8List encodeJpegXl(Image image) => const JpegXlCodec().encode(image);

/// Encodes [image] as lossless JPEG XL Modular data.
Uint8List encodeJxl(Image image) => encodeJpegXl(image);

/// Encodes [image] as an 8-bit RGBA PNG.
Uint8List encodePng(Image image, {int level = 6}) => PngCodec(level: level).encode(image);

/// Encodes [image] as a lossless Quite OK Image.
Uint8List encodeQoi(Image image) => const QoiCodec().encode(image);

/// Encodes [image] as a 32-bit TGA image.
/// Run-length encoding is enabled by default and can be disabled for consumers
/// that only support uncompressed true-color TGA files.
Uint8List encodeTga(Image image, {bool runLengthEncoding = true}) => TgaCodec(runLengthEncoding: runLengthEncoding).encode(image);

/// Encodes [image] as an eight-bit RGBA TIFF image.
Uint8List encodeTiff(Image image, {TiffCompression compression = TiffCompression.packBits}) => TiffCodec(compression: compression).encode(image);

/// Encodes [image] as a baseline JPEG.
/// Transparent pixels are composited against white because JPEG has no alpha
/// channel. [quality] is clamped to the range 1 through 100.
Uint8List encodeJpg(Image image, {int quality = 100, JpegChroma chroma = JpegChroma.yuv444}) => JpegCodec(quality: quality, chroma: chroma).encode(image);

/// Encodes [image] as a baseline JPEG.
Uint8List encodeJpeg(Image image, {int quality = 100, JpegChroma chroma = JpegChroma.yuv444}) => encodeJpg(image, quality: quality, chroma: chroma);

/// Encodes [image] as a lossless VP8L WebP image.
Uint8List encodeWebP(Image image) => const WebPCodec().encode(image);
