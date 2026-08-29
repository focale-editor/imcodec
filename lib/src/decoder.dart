import 'dart:typed_data';

import 'package:imcodec/src/codecs/bmp.dart';
import 'package:imcodec/src/codecs/gif.dart';
import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl.dart';
import 'package:imcodec/src/codecs/png.dart';
import 'package:imcodec/src/codecs/qoi.dart';
import 'package:imcodec/src/codecs/raster_codec.dart';
import 'package:imcodec/src/codecs/tga.dart';
import 'package:imcodec/src/codecs/tiff.dart';
import 'package:imcodec/src/codecs/webp.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';

/// Decodes a supported image synchronously to straight RGBA.
/// [maxPixels] limits allocation after the image header has been inspected.
Image decodeImage(Uint8List bytes, {int maxPixels = defaultMaxPixels}) {
  final ImageFormat? format = ImageFormat.sniff(bytes);
  if (format == null) {
    throw const ImageCodecException('The encoded image format is not supported');
  }
  return switch (format) {
    ImageFormat.bmp => decodeBmp(bytes, maxPixels: maxPixels),
    ImageFormat.gif => decodeGif(bytes, maxPixels: maxPixels),
    ImageFormat.jpeg => decodeJpg(bytes, maxPixels: maxPixels),
    ImageFormat.jpegXl => decodeJpegXl(bytes, maxPixels: maxPixels),
    ImageFormat.png => decodePng(bytes, maxPixels: maxPixels),
    ImageFormat.qoi => decodeQoi(bytes, maxPixels: maxPixels),
    ImageFormat.tga => decodeTga(bytes, maxPixels: maxPixels),
    ImageFormat.tiff => decodeTiff(bytes, maxPixels: maxPixels),
    ImageFormat.webp => decodeWebP(bytes, maxPixels: maxPixels),
  };
}

/// Decodes an uncompressed or bitfield BMP image to straight RGBA.
Image decodeBmp(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => BmpCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes the first visible GIF frame to straight RGBA.
Image decodeGif(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => GifCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes the first frame of a PNG image to straight RGBA.
Image decodePng(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => PngCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes a JPEG image to opaque RGBA.
Image decodeJpg(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => JpegCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes the first visible frame of a JPEG XL image to straight RGBA.
Image decodeJpegXl(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => JpegXlCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes the first visible frame of a JPEG XL image to straight RGBA.
Image decodeJxl(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => decodeJpegXl(bytes, maxPixels: maxPixels);

/// Decodes a Quite OK Image to straight RGBA.
Image decodeQoi(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => QoiCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes an uncompressed or run-length encoded TGA image to straight RGBA.
Image decodeTga(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => TgaCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes the first image-file directory of a baseline TIFF image.
Image decodeTiff(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => TiffCodec(maxPixels: maxPixels).decode(bytes);

/// Decodes the first frame of a WebP image to straight RGBA.
Image decodeWebP(Uint8List bytes, {int maxPixels = defaultMaxPixels}) => WebPCodec(maxPixels: maxPixels).decode(bytes);
