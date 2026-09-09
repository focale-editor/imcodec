import 'dart:typed_data';

import 'package:imcodec/src/codecs/bmp.dart';
import 'package:imcodec/src/codecs/gif.dart';
import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl.dart';
import 'package:imcodec/src/codecs/open_exr.dart';
import 'package:imcodec/src/codecs/png.dart';
import 'package:imcodec/src/codecs/qoi.dart';
import 'package:imcodec/src/codecs/raster_codec.dart';
import 'package:imcodec/src/codecs/tga.dart';
import 'package:imcodec/src/codecs/tiff.dart';
import 'package:imcodec/src/codecs/webp.dart';
import 'package:imcodec/src/formats/image_format.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/parallel_runner.dart';
import 'package:imcodec/src/registry/registry.dart';

/// Encodes [image] as a 32-bit BMP with alpha bitfields.
Uint8List encodeBmp(
  Image image, {
  BmpEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.bmp,
  options: options,
);

/// Encodes [image] as one static palette-indexed GIF frame.
Uint8List encodeGif(
  Image image, {
  GifEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.gif,
  options: options,
);

/// Encodes [image] as lossless JPEG XL Modular data.
Uint8List encodeJpegXl(
  Image image, {
  JpegXlEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.jpegXl,
  options: options,
);

/// Encodes [image] as lossless JPEG XL Modular data.
Uint8List encodeJxl(
  Image image, {
  JpegXlEncodeOptions? options,
}) => encodeJpegXl(
  image,
  options: options,
);

/// Encodes [image] as a scene-linear half-float OpenEXR image.
Uint8List encodeOpenExr(
  Image image, {
  OpenExrEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.openExr,
  options: options,
);

/// Encodes straight extended-sRGB float samples as half-float OpenEXR.
///
/// Values outside the display range are preserved when representable as an
/// IEEE-754 binary16 sample. Alpha is constrained to zero through one.
Uint8List encodeOpenExrFloat32Rgba({
  required int width,
  required int height,
  required Float32List pixels,
  OpenExrEncodeOptions? options,
}) => OpenExrEncoder.encodeFloat32Rgba(
  width: width,
  height: height,
  pixels: pixels,
  options: options ?? const OpenExrEncodeOptions(),
);

/// Encodes [image] as lossless JPEG XL Modular data through [runner].
Future<Uint8List> encodeJpegXlWith(
  ParallelRunner runner,
  Image image, {
  JpegXlEncodeOptions? options,
}) => encodeImageWith(
  runner,
  image,
  format: ImageFormat.jpegXl,
  options: options,
);

/// Encodes [image] as an 8-bit RGBA PNG.
Uint8List encodePng(
  Image image, {
  PngEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.png,
  options: options,
);

/// Encodes [image] as an 8-bit RGBA PNG through [runner].
Future<Uint8List> encodePngWith(
  ParallelRunner runner,
  Image image, {
  PngEncodeOptions? options,
}) => encodeImageWith(
  runner,
  image,
  format: ImageFormat.png,
  options: options,
);

/// Encodes [image] as a lossless Quite OK Image.
Uint8List encodeQoi(
  Image image, {
  QoiEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.qoi,
  options: options,
);

/// Encodes [image] as a 32-bit TGA image.
Uint8List encodeTga(
  Image image, {
  TgaEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.tga,
  options: options,
);

/// Encodes [image] as an eight-bit RGBA TIFF image.
Uint8List encodeTiff(
  Image image, {
  TiffEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.tiff,
  options: options,
);

/// Encodes [image] as a baseline JPEG.
///
/// Transparent pixels are composited against white because JPEG has no alpha
/// channel.
Uint8List encodeJpg(
  Image image, {
  JpegEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.jpeg,
  options: options,
);

/// Encodes [image] as a baseline JPEG.
Uint8List encodeJpeg(
  Image image, {
  JpegEncodeOptions? options,
}) => encodeJpg(
  image,
  options: options,
);

/// Encodes [image] as a baseline JPEG through [runner].
Future<Uint8List> encodeJpgWith(
  ParallelRunner runner,
  Image image, {
  JpegEncodeOptions? options,
}) => encodeImageWith(
  runner,
  image,
  format: ImageFormat.jpeg,
  options: options,
);

/// Encodes [image] as a baseline JPEG through [runner].
Future<Uint8List> encodeJpegWith(
  ParallelRunner runner,
  Image image, {
  JpegEncodeOptions? options,
}) => encodeJpgWith(
  runner,
  image,
  options: options,
);

/// Encodes [image] as lossless VP8L or lossy VP8 WebP data.
Uint8List encodeWebP(
  Image image, {
  WebPEncodeOptions? options,
}) => encodeImage(
  image,
  format: ImageFormat.webp,
  options: options,
);

/// Encodes [image] as WebP through [runner].
Future<Uint8List> encodeWebPWith(
  ParallelRunner runner,
  Image image, {
  WebPEncodeOptions? options,
}) => encodeImageWith(
  runner,
  image,
  format: ImageFormat.webp,
  options: options,
);

/// Encodes [image] to [format], offering [runner] independent work.
///
/// A non-parallel extension encodes inline while preserving the same public
/// dispatch path.
Future<Uint8List> encodeImageWith<Options extends RasterEncodeOptions>(
  ParallelRunner runner,
  Image image, {
  required ImageFormat format,
  Options? options,
}) async {
  final ImageCodecExtension extension = ImageCodecRegistry.require(format);
  if (extension is ParallelImageCodecExtension) {
    return extension.encodeWith(
      runner,
      image,
      encodeOptions: options,
    );
  }
  return extension.encode(
    image,
    encodeOptions: options,
  );
}

/// Encodes [image] to [format] with format-specific [options].
Uint8List encodeImage<Options extends RasterEncodeOptions>(
  Image image, {
  required ImageFormat format,
  Options? options,
}) => ImageCodecRegistry.require(format).encode(
  image,
  encodeOptions: options,
);
