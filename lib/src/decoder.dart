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
import 'package:imcodec/src/decoded_image.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';
import 'package:imcodec/src/image_metadata.dart';

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

/// Default maximum number of sample bytes one decoded raster may hold.
///
/// A pixel of [defaultMaxPixels] RGBA8 data occupies four bytes, so this keeps
/// wider channels and CMYK process data inside the allocation budget that
/// [decodeImage] already implies.
const int defaultMaxDecodedBytes = defaultMaxPixels * 4;

/// Decodes native process samples and attaches supported container metadata.
///
/// PNG and TIFF keep unsigned sixteen-bit samples, TIFF keeps float32 samples,
/// and four-component JPEG/TIFF files retain CMYK+A instead of being flattened
/// to RGB. Other formats currently return their ordinary RGBA8 decode.
DecodedImage decodeImageData(
  Uint8List bytes, {
  int maxPixels = defaultMaxPixels,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(bytes, null, maxPixels, maxDecodedBytes, maxIccProfileBytes);

/// Decodes PNG data while preserving unsigned sixteen-bit samples.
DecodedImage decodePngData(
  Uint8List bytes, {
  int maxPixels = defaultMaxPixels,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(bytes, ImageFormat.png, maxPixels, maxDecodedBytes, maxIccProfileBytes);

/// Decodes JPEG data while preserving native CMYK components when present.
DecodedImage decodeJpgData(
  Uint8List bytes, {
  int maxPixels = defaultMaxPixels,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(bytes, ImageFormat.jpeg, maxPixels, maxDecodedBytes, maxIccProfileBytes);

/// Decodes TIFF data while preserving integer or floating-point samples.
DecodedImage decodeTiffData(
  Uint8List bytes, {
  int maxPixels = defaultMaxPixels,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(bytes, ImageFormat.tiff, maxPixels, maxDecodedBytes, maxIccProfileBytes);

/// Decodes native samples, rejecting anything but [expected] when it is given.
DecodedImage _decodeData(
  Uint8List bytes,
  ImageFormat? expected,
  int maxPixels,
  int maxDecodedBytes,
  int maxIccProfileBytes,
) {
  if (maxDecodedBytes < 1) {
    throw RangeError.range(maxDecodedBytes, 1, null, 'maxDecodedBytes');
  }
  final ImageFormat? format = ImageFormat.sniff(bytes);
  if (format == null) {
    throw const ImageCodecException(
      'The encoded image format is not supported',
    );
  }
  if (expected != null && format != expected) {
    throw ImageCodecException(
      'Expected ${expected.name} data, received ${format.name}',
    );
  }
  final DecodedImageMetadata? metadata = inspectImage(
    bytes,
    maxIccProfileBytes: maxIccProfileBytes,
  );
  if (metadata != null) {
    _checkDecodedSize(metadata, maxPixels, maxDecodedBytes);
  }
  final DecodedImage decoded = switch (format) {
    ImageFormat.jpeg => const JpegDecoder().decodeData(
      bytes,
      maxPixels: maxPixels,
    ),
    ImageFormat.png => const PngDecoder().decodeData(
      bytes,
      maxPixels: maxPixels,
    ),
    ImageFormat.tiff => const TiffDecoder().decodeData(
      bytes,
      maxPixels: maxPixels,
    ),
    _ => DecodedImage.fromImage(
      decodeImage(bytes, maxPixels: maxPixels),
    ),
  };
  if (metadata != null && metadata.colorModel != decoded.colorModel) {
    throw const ImageCodecException(
      'Decoded process channels do not match the image container metadata',
    );
  }
  return metadata?.iccProfile == null ? decoded : decoded.withIccProfile(metadata!.iccProfile);
}

/// Rejects rasters whose native samples would exceed [maxDecodedBytes].
///
/// Sample width and process channel count both scale the memory one pixel
/// needs, so a pixel budget alone no longer bounds it. The estimate covers the
/// returned raster; decoders may hold one comparable buffer while converting.
void _checkDecodedSize(
  DecodedImageMetadata metadata,
  int maxPixels,
  int maxDecodedBytes,
) {
  if (metadata.width < 1 || metadata.height < 1 || metadata.width > maxPixels || metadata.height > maxPixels) {
    // Decoding reports the exact dimension or pixel-limit problem itself.
    return;
  }
  final int bytesPerPixel = (metadata.colorModel.processChannelCount + 1) * ((metadata.bitsPerChannel + 7) ~/ 8);
  final int decodedBytes = metadata.width * metadata.height * bytesPerPixel;
  if (decodedBytes > maxDecodedBytes) {
    throw ImageCodecException(
      'Decoded samples need $decodedBytes bytes, exceeding the $maxDecodedBytes byte limit',
    );
  }
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
