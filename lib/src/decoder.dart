import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:imcodec/src/codecs/bmp_codec.dart';
import 'package:imcodec/src/codecs/qoi_codec.dart';
import 'package:imcodec/src/codecs/tga_codec.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';

/// Decodes a supported image to straight RGBA.
///
/// [maxPixels] limits allocation after Flutter has inspected the image header.
Future<Image> decodeImage(Uint8List bytes, {int maxPixels = 100000000}) {
  final ImageFormat? format = ImageFormat.sniff(bytes);
  if (format == null) {
    throw const ImageCodecException('The encoded image format is not supported');
  }
  return switch (format) {
    ImageFormat.bmp => decodeBmp(bytes, maxPixels: maxPixels),
    ImageFormat.jpeg || ImageFormat.png || ImageFormat.webp => _decodeWithFlutter(bytes, format, maxPixels),
    ImageFormat.qoi => decodeQoi(bytes, maxPixels: maxPixels),
    ImageFormat.tga => decodeTga(bytes, maxPixels: maxPixels),
  };
}

/// Decodes an uncompressed or bitfield BMP image to straight RGBA.
Future<Image> decodeBmp(Uint8List bytes, {int maxPixels = 100000000}) => _decodeWithDart(bytes, ImageFormat.bmp, () => const BmpDecoder().decode(bytes, maxPixels: maxPixels));

/// Decodes the first frame of a PNG image to straight RGBA.
Future<Image> decodePng(Uint8List bytes, {int maxPixels = 100000000}) => _decodeWithFlutter(bytes, ImageFormat.png, maxPixels);

/// Decodes a JPEG image to opaque RGBA.
Future<Image> decodeJpg(Uint8List bytes, {int maxPixels = 100000000}) => _decodeWithFlutter(bytes, ImageFormat.jpeg, maxPixels);

/// Decodes a Quite OK Image to straight RGBA.
Future<Image> decodeQoi(Uint8List bytes, {int maxPixels = 100000000}) => _decodeWithDart(bytes, ImageFormat.qoi, () => const QoiDecoder().decode(bytes, maxPixels: maxPixels));

/// Decodes an uncompressed or run-length encoded TGA image to straight RGBA.
Future<Image> decodeTga(Uint8List bytes, {int maxPixels = 100000000}) => _decodeWithDart(bytes, ImageFormat.tga, () => const TgaDecoder().decode(bytes, maxPixels: maxPixels));

/// Decodes the first frame of a WebP image to straight RGBA.
Future<Image> decodeWebP(Uint8List bytes, {int maxPixels = 100000000}) => _decodeWithFlutter(bytes, ImageFormat.webp, maxPixels);

/// Runs a pure-Dart decoder while normalizing errors and format checks.
Future<Image> _decodeWithDart(Uint8List bytes, ImageFormat expectedFormat, Image Function() decode) => Future<Image>.sync(() {
  final ImageFormat? actualFormat = ImageFormat.sniff(bytes);
  if (actualFormat != expectedFormat) {
    throw ImageCodecException('Expected ${expectedFormat.name} data, found ${actualFormat?.name ?? 'an unknown format'}');
  }
  try {
    return decode();
  } on ImageCodecException {
    rethrow;
  } on Object catch (error) {
    throw ImageCodecException('Could not decode the ${expectedFormat.name} image', cause: error);
  }
});

/// Uses Flutter's native codecs for formats supported by the engine.
Future<Image> _decodeWithFlutter(Uint8List bytes, ImageFormat expectedFormat, int maxPixels) async {
  if (maxPixels < 1) {
    throw RangeError.range(maxPixels, 1, null, 'maxPixels');
  }
  final ImageFormat? actualFormat = ImageFormat.sniff(bytes);
  if (actualFormat != expectedFormat) {
    throw ImageCodecException('Expected ${expectedFormat.name} data, found ${actualFormat?.name ?? 'an unknown format'}');
  }

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? decoded;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final int pixelCount = descriptor.width * descriptor.height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
    codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    decoded = frame.image;
    final ByteData? byteData = await decoded.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (byteData == null) {
      throw const ImageCodecException('Flutter returned no decoded pixel data');
    }
    final Uint8List rgba = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
    return Image.fromRgba(width: decoded.width, height: decoded.height, bytes: rgba);
  } on ImageCodecException {
    rethrow;
  } on Object catch (error) {
    throw ImageCodecException('Could not decode the ${expectedFormat.name} image', cause: error);
  } finally {
    decoded?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
