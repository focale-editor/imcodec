import 'dart:typed_data';

import 'package:imcodec/src/codecs/bmp.dart';
import 'package:imcodec/src/codecs/gif.dart';
import 'package:imcodec/src/codecs/gif/indexed_color.dart';
import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl.dart';
import 'package:imcodec/src/codecs/png.dart';
import 'package:imcodec/src/codecs/qoi.dart';
import 'package:imcodec/src/codecs/tga.dart';
import 'package:imcodec/src/codecs/tiff.dart';
import 'package:imcodec/src/codecs/webp.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_format.dart';
import 'package:imcodec/src/parallel_runner.dart';

/// Encodes [image] to [format].
///
/// [quality] only affects JPEG output. [webPQuality] selects lossy WebP when
/// supplied; omitting it keeps WebP lossless. [pngLevel] is the zlib
/// compression level and ranges from zero through nine. [jpegXlEffort] and
/// [webPEffort] control how thoroughly their encoders search.
Uint8List encodeImage(
  Image image, {
  required ImageFormat format,
  int quality = 90,
  int pngLevel = 6,
  JpegXlEffort jpegXlEffort = JpegXlEffort.balanced,
  int? webPQuality,
  WebPEffort webPEffort = WebPEffort.balanced,
}) => switch (format) {
  ImageFormat.bmp => encodeBmp(image),
  ImageFormat.gif => encodeGif(image),
  ImageFormat.jpeg => encodeJpg(image, quality: quality),
  ImageFormat.jpegXl => encodeJpegXl(image, effort: jpegXlEffort),
  ImageFormat.png => encodePng(image, level: pngLevel),
  ImageFormat.qoi => encodeQoi(image),
  ImageFormat.tga => encodeTga(image),
  ImageFormat.tiff => encodeTiff(image),
  ImageFormat.webp => encodeWebP(
    image,
    quality: webPQuality,
    effort: webPEffort,
  ),
};

/// Encodes [image] as a 32-bit BMP with alpha bitfields.
Uint8List encodeBmp(Image image) => const BmpCodec().encode(image);

/// Encodes [image] as one static palette-indexed GIF frame.
Uint8List encodeGif(
  Image image, {
  IndexedColorOptions options = const IndexedColorOptions(),
}) => GifCodec(options: options).encode(image);

/// Encodes [image] as lossless JPEG XL Modular data.
/// [effort] trades encoding speed against output size.
Uint8List encodeJpegXl(
  Image image, {
  JpegXlEffort effort = JpegXlEffort.balanced,
}) => JpegXlCodec(effort: effort).encode(image);

/// Encodes [image] as lossless JPEG XL Modular data.
Uint8List encodeJxl(
  Image image, {
  JpegXlEffort effort = JpegXlEffort.balanced,
}) => encodeJpegXl(image, effort: effort);

/// Encodes [image] as lossless JPEG XL Modular data, spreading the work with
/// [runner].
///
/// The result is identical to [encodeJpegXl] with the same [effort]. This
/// package never starts an isolate itself, so [runner] owns that decision; see
/// [ParallelRunner] for a two-line isolate implementation.
Future<Uint8List> encodeJpegXlWith(
  ParallelRunner runner,
  Image image, {
  JpegXlEffort effort = JpegXlEffort.balanced,
}) => JpegXlCodec(effort: effort).encodeWith(runner, image);

/// Encodes [image] as an 8-bit RGBA PNG.
Uint8List encodePng(
  Image image, {
  int level = 6,
}) => PngCodec(level: level).encode(image);

/// Encodes [image] as an 8-bit RGBA PNG, filtering independent row bands
/// through [runner] when the image is large enough to benefit.
Future<Uint8List> encodePngWith(
  ParallelRunner runner,
  Image image, {
  int level = 6,
}) => PngCodec(level: level).encodeWith(runner, image);

/// Encodes [image] as a lossless Quite OK Image.
Uint8List encodeQoi(
  Image image,
) => const QoiCodec().encode(image);

/// Encodes [image] as a 32-bit TGA image.
/// Run-length encoding is enabled by default and can be disabled for consumers
/// that only support uncompressed true-color TGA files.
Uint8List encodeTga(
  Image image, {
  bool runLengthEncoding = true,
}) => TgaCodec(runLengthEncoding: runLengthEncoding).encode(image);

/// Encodes [image] as an eight-bit RGBA TIFF image.
Uint8List encodeTiff(
  Image image, {
  TiffCompression compression = TiffCompression.packBits,
}) => TiffCodec(compression: compression).encode(image);

/// Encodes [image] as a baseline JPEG.
/// Transparent pixels are composited against white because JPEG has no alpha
/// channel. [quality] is clamped to the range 1 through 100.
Uint8List encodeJpg(
  Image image, {
  int quality = 100,
  JpegChroma chroma = JpegChroma.yuv444,
}) => JpegCodec(quality: quality, chroma: chroma).encode(image);

/// Encodes [image] as a baseline JPEG.
Uint8List encodeJpeg(
  Image image, {
  int quality = 100,
  JpegChroma chroma = JpegChroma.yuv444,
}) => encodeJpg(image, quality: quality, chroma: chroma);

/// Encodes [image] as a baseline JPEG, transforming independent MCU bands
/// through [runner] when the image is large enough to benefit.
Future<Uint8List> encodeJpgWith(
  ParallelRunner runner,
  Image image, {
  int quality = 100,
  JpegChroma chroma = JpegChroma.yuv444,
}) => JpegCodec(quality: quality, chroma: chroma).encodeWith(runner, image);

/// Encodes [image] as a baseline JPEG through [runner].
Future<Uint8List> encodeJpegWith(
  ParallelRunner runner,
  Image image, {
  int quality = 100,
  JpegChroma chroma = JpegChroma.yuv444,
}) => encodeJpgWith(runner, image, quality: quality, chroma: chroma);

/// Encodes [image] as WebP.
///
/// Omitting [quality] produces lossless VP8L data. Supplying it produces lossy
/// VP8 data, with values outside zero through 100 clamped to that range.
Uint8List encodeWebP(
  Image image, {
  int? quality,
  WebPEffort effort = WebPEffort.balanced,
}) => WebPCodec(quality: quality, effort: effort).encode(image);

/// Encodes [image] as WebP through [runner].
///
/// Lossless encoding may distribute predictor-block bands when the image is
/// large enough. Lossy encoding currently runs inline and still returns the
/// same bytes as [encodeWebP].
Future<Uint8List> encodeWebPWith(
  ParallelRunner runner,
  Image image, {
  int? quality,
  WebPEffort effort = WebPEffort.balanced,
}) => WebPCodec(quality: quality, effort: effort).encodeWith(runner, image);

/// Encodes [image] to [format], offering [runner] the work that can run
/// independently.
///
/// The bytes match [encodeImage] with the same options, so a runner is always
/// safe to pass. JPEG, JPEG XL, PNG, and WebP split expensive independent
/// phases for sufficiently large images. The lighter or stateful formats
/// encode inline because isolate transfer would make them slower.
Future<Uint8List> encodeImageWith(
  ParallelRunner runner,
  Image image, {
  required ImageFormat format,
  int quality = 90,
  int pngLevel = 6,
  JpegXlEffort jpegXlEffort = JpegXlEffort.balanced,
  int? webPQuality,
  WebPEffort webPEffort = WebPEffort.balanced,
}) async => switch (format) {
  ImageFormat.bmp => const BmpCodec().encode(image),
  ImageFormat.gif => GifCodec().encode(image),
  ImageFormat.jpeg => await JpegCodec(quality: quality).encodeWith(runner, image),
  ImageFormat.jpegXl => await JpegXlCodec(effort: jpegXlEffort).encodeWith(runner, image),
  ImageFormat.png => await PngCodec(level: pngLevel).encodeWith(runner, image),
  ImageFormat.qoi => const QoiCodec().encode(image),
  ImageFormat.tga => TgaCodec().encode(image),
  ImageFormat.tiff => TiffCodec().encode(image),
  ImageFormat.webp => await encodeWebPWith(
    runner,
    image,
    quality: webPQuality,
    effort: webPEffort,
  ),
};
