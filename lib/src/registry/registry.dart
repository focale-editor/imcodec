import 'dart:collection';
import 'dart:typed_data';

import 'package:imcodec/src/codecs/bmp.dart';
import 'package:imcodec/src/codecs/exception.dart';
import 'package:imcodec/src/codecs/gif.dart';
import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl.dart';
import 'package:imcodec/src/codecs/jpeg_xl/info.dart';
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
import 'package:imcodec/src/parallel_runner.dart';

part 'extensions/bmp.dart';
part 'extensions/extension.dart';
part 'extensions/gif.dart';
part 'extensions/jpeg.dart';
part 'extensions/jpeg_xl.dart';
part 'extensions/open_exr.dart';
part 'extensions/png.dart';
part 'extensions/qoi.dart';
part 'extensions/tga.dart';
part 'extensions/tiff.dart';
part 'extensions/webp.dart';

/// Isolate-local registry of explicitly installed optional codecs.
///
/// Extensions replace the complete generic codec entry for a format. Direct
/// codec instances remain unchanged. Install during startup in each isolate.
abstract final class ImageCodecRegistry {
  /// Pure-Dart codecs supplied by Imcodec itself.
  static final Map<ImageFormat, ImageCodecExtension> _builtInExtensions = HashMap<ImageFormat, ImageCodecExtension>.identity()
    ..addAll({
      ImageFormat.bmp: const _BmpCodecExtension(),
      ImageFormat.gif: const _GifCodecExtension(),
      ImageFormat.jpeg: const _JpegCodecExtension(),
      ImageFormat.jpegXl: const _JpegXlCodecExtension(),
      ImageFormat.openExr: const _OpenExrCodecExtension(),
      ImageFormat.png: const _PngCodecExtension(),
      ImageFormat.qoi: const _QoiCodecExtension(),
      ImageFormat.tga: const _TgaCodecExtension(),
      ImageFormat.tiff: const _TiffCodecExtension(),
      ImageFormat.webp: const _WebPCodecExtension(),
    });

  /// Explicit add-on codecs, keyed by format identity.
  static final Map<ImageFormat, ImageCodecExtension> _extensions = HashMap<ImageFormat, ImageCodecExtension>.identity();

  /// Installs [extension], replacing a previous extension for the same format.
  static void register(ImageCodecExtension extension) {
    _extensions[extension.format] = extension;
  }

  /// Returns the active add-on or built-in codec for [format].
  static ImageCodecExtension? lookup(ImageFormat format) => _extensions[format] ?? _builtInExtensions[format];

  /// Removes an optional codec from this isolate.
  static void unregister(ImageFormat format) => _extensions.remove(format);

  /// Returns the installed codec for [format], or reports missing registration.
  static ImageCodecExtension require(ImageFormat format) => lookup(format) ?? (throw ImageCodecException('The ${format.name} format requires a registered ImageCodecExtension'));
}
