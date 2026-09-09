import 'dart:typed_data';

import 'package:imcodec/src/codecs/bmp.dart';
import 'package:imcodec/src/codecs/exception.dart';
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
import 'package:imcodec/src/decoded_image.dart';
import 'package:imcodec/src/formats/image_format.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_metadata.dart';
import 'package:imcodec/src/registry/registry.dart';

/// Default maximum number of sample bytes one decoded raster may hold.
///
/// A pixel of the default RGBA8 pixel limit occupies four bytes. Wider samples
/// and CMYK process data are checked against this independent byte budget.
const int defaultMaxDecodedBytes = RasterDecodeOptions.defaultMaxPixels * 4;

/// Decodes native process samples and attaches supported container metadata.
///
/// PNG and TIFF keep unsigned sixteen-bit samples, TIFF keeps float32 samples,
/// and four-component JPEG/TIFF files retain CMYK+A instead of being flattened
/// to RGB. When supplied, [options] must match the detected format.
DecodedImage decodeImageData<Options extends RasterDecodeOptions>(
  Uint8List bytes, {
  Options? options,
  int? maxPixels,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(
  bytes,
  expected: null,
  options: options,
  maxPixels: maxPixels,
  maxDecodedBytes: maxDecodedBytes,
  maxIccProfileBytes: maxIccProfileBytes,
);

/// Decodes PNG data while preserving unsigned sixteen-bit samples.
DecodedImage decodePngData(
  Uint8List bytes, {
  PngDecodeOptions? options,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(
  bytes,
  expected: ImageFormat.png,
  options: options,
  maxPixels: null,
  maxDecodedBytes: maxDecodedBytes,
  maxIccProfileBytes: maxIccProfileBytes,
);

/// Decodes JPEG data while preserving native CMYK components when present.
DecodedImage decodeJpgData(
  Uint8List bytes, {
  JpegDecodeOptions? options,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(
  bytes,
  expected: ImageFormat.jpeg,
  options: options,
  maxPixels: null,
  maxDecodedBytes: maxDecodedBytes,
  maxIccProfileBytes: maxIccProfileBytes,
);

/// Decodes TIFF data while preserving integer or floating-point samples.
DecodedImage decodeTiffData(
  Uint8List bytes, {
  TiffDecodeOptions? options,
  int maxDecodedBytes = defaultMaxDecodedBytes,
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
}) => _decodeData(
  bytes,
  expected: ImageFormat.tiff,
  options: options,
  maxPixels: null,
  maxDecodedBytes: maxDecodedBytes,
  maxIccProfileBytes: maxIccProfileBytes,
);

/// Decodes OpenEXR data while preserving floating-point HDR samples.
DecodedImage decodeOpenExrData(
  Uint8List bytes, {
  OpenExrDecodeOptions? options,
  int maxDecodedBytes = defaultMaxDecodedBytes,
}) => _decodeData(
  bytes,
  expected: ImageFormat.openExr,
  options: options,
  maxPixels: null,
  maxDecodedBytes: maxDecodedBytes,
  maxIccProfileBytes: defaultMaxIccProfileBytes,
);

/// Decodes native samples, rejecting anything but [expected] when supplied.
DecodedImage _decodeData<Options extends RasterDecodeOptions>(
  Uint8List bytes, {
  required ImageFormat? expected,
  required Options? options,
  required int? maxPixels,
  required int maxDecodedBytes,
  required int maxIccProfileBytes,
}) {
  if (maxDecodedBytes < 1) {
    throw RangeError.range(
      maxDecodedBytes,
      1,
      null,
      'maxDecodedBytes',
    );
  }
  final ImageFormat? format = ImageFormat.sniff(bytes);
  if (format == null) {
    throw const ImageCodecException('The encoded image format is not supported');
  }
  if (expected != null && !identical(format, expected)) {
    throw ImageCodecException(
      'Expected ${expected.name} data, received ${format.name}',
    );
  }

  if (options != null && maxPixels != null) {
    throw ArgumentError('Pass either options or maxPixels, not both');
  }
  final int resolvedMaxPixels = maxPixels ?? options?.maxPixels ?? RasterDecodeOptions.defaultMaxPixels;
  if (resolvedMaxPixels < 1) {
    throw RangeError.range(resolvedMaxPixels, 1, null, 'maxPixels');
  }
  final DecodedImageMetadata? metadata = inspectImage(
    bytes,
    maxIccProfileBytes: maxIccProfileBytes,
  );
  if (metadata != null) {
    _checkDecodedSize(
      metadata,
      resolvedMaxPixels,
      maxDecodedBytes,
    );
  }

  final ImageCodecExtension registry = ImageCodecRegistry.require(format);
  final DecodedImage decoded = registry.decodeData(
    bytes,
    decodeOptions: options,
    maxDecodedBytes: maxDecodedBytes,
    maxIccProfileBytes: maxIccProfileBytes,
  );
  final int pixelCount = decoded.width * decoded.height;
  if (pixelCount > resolvedMaxPixels) {
    throw ImageCodecException(
      'Decoded image contains $pixelCount pixels, exceeding the $resolvedMaxPixels pixel limit',
    );
  }
  if (decoded.bytes.lengthInBytes > maxDecodedBytes) {
    throw ImageCodecException(
      'Decoded samples need ${decoded.bytes.lengthInBytes} bytes, exceeding the $maxDecodedBytes byte limit',
    );
  }
  if (metadata != null && metadata.colorModel != decoded.colorModel) {
    throw const ImageCodecException('Decoded process channels do not match the image container metadata');
  }
  return metadata?.iccProfile == null ? decoded : decoded.withIccProfile(metadata!.iccProfile);
}

/// Rejects rasters whose native samples would exceed [maxDecodedBytes].
void _checkDecodedSize(
  DecodedImageMetadata metadata,
  int maxPixels,
  int maxDecodedBytes,
) {
  if (metadata.width < 1 || metadata.height < 1) {
    throw const ImageCodecException('Image dimensions must be positive and non-zero');
  }
  final int pixelCount = metadata.width * metadata.height;
  if (pixelCount > maxPixels) {
    throw ImageCodecException(
      'Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit',
    );
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
Image decodeBmp(
  Uint8List bytes, {
  BmpDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes the first visible GIF frame to straight RGBA.
Image decodeGif(
  Uint8List bytes, {
  GifDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes the first frame of a PNG image to straight RGBA.
Image decodePng(
  Uint8List bytes, {
  PngDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes a JPEG image to opaque RGBA.
Image decodeJpg(
  Uint8List bytes, {
  JpegDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes the first visible frame of a JPEG XL image to straight RGBA.
Image decodeJpegXl(
  Uint8List bytes, {
  JpegXlDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes the first visible frame of a JPEG XL image to straight RGBA.
Image decodeJxl(
  Uint8List bytes, {
  JpegXlDecodeOptions? options,
}) => decodeJpegXl(
  bytes,
  options: options,
);

/// Decodes one single-part OpenEXR scan-line image to straight RGBA8.
Image decodeOpenExr(
  Uint8List bytes, {
  OpenExrDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes a Quite OK Image to straight RGBA.
Image decodeQoi(
  Uint8List bytes, {
  QoiDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes an uncompressed or run-length encoded TGA image to straight RGBA.
Image decodeTga(
  Uint8List bytes, {
  TgaDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes the first image-file directory of a baseline TIFF image.
Image decodeTiff(
  Uint8List bytes, {
  TiffDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes the first frame of a WebP image to straight RGBA.
Image decodeWebP(
  Uint8List bytes, {
  WebPDecodeOptions? options,
}) => decodeImage(
  bytes,
  options: options,
);

/// Decodes a supported image synchronously to straight RGBA.
///
/// When supplied, [options] must match the format detected from [bytes].
Image decodeImage<Options extends RasterDecodeOptions>(
  Uint8List bytes, {
  Options? options,
}) {
  final ImageFormat? format = ImageFormat.sniff(bytes);
  if (format == null) {
    throw const ImageCodecException('The encoded image format is not supported');
  }
  return ImageCodecRegistry.require(format).decode(
    bytes,
    decodeOptions: options,
  );
}
