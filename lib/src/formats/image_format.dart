import 'dart:typed_data';

import 'package:imcodec/src/codecs/exception.dart';
import 'package:imcodec/src/decoded_image.dart';
import 'package:zcodec/zcodec.dart';

part 'bmp.dart';
part 'gif.dart';
part 'jpeg.dart';
part 'jpeg_xl.dart';
part 'open_exr.dart';
part 'png.dart';
part 'qoi.dart';
part 'tga.dart';
part 'tiff.dart';
part 'webp.dart';

/// A named image format with its own file-signature matcher.
///
/// Add-on packages subclass this type for any additional format-specific
/// properties, then install their canonical instance in [ImageFormatRegistry].
abstract class ImageFormat {
  /// Windows bitmap image.
  static const ImageFormat bmp = _BmpFormat();

  /// Graphics Interchange Format image.
  static const ImageFormat gif = _GifFormat();

  /// Joint Photographic Experts Group image.
  static const ImageFormat jpeg = _JpegFormat();

  /// JPEG XL image.
  static const ImageFormat jpegXl = _JpegXlFormat();

  /// OpenEXR high-dynamic-range image.
  static const ImageFormat openExr = _OpenExrFormat();

  /// Portable Network Graphics image.
  static const ImageFormat png = _PngFormat();

  /// Quite OK Image.
  static const ImageFormat qoi = _QoiFormat();

  /// Truevision TGA image.
  static const ImageFormat tga = _TgaFormat();

  /// Tagged Image File Format image.
  static const ImageFormat tiff = _TiffFormat();

  /// WebP image.
  static const ImageFormat webp = _WebPFormat();

  /// Stable human-readable format identifier.
  final String name;

  /// Creates a format that can be installed in [ImageFormatRegistry].
  ///
  /// Reuse one constant per format: format keys have identity semantics.
  const ImageFormat({
    required this.name,
  }) : assert(name != '', 'Image format names must not be empty.');

  /// Whether [bytes] carry this format's file signature.
  bool matches(Uint8List bytes);

  /// Detects the first matching format currently installed in the registry.
  static ImageFormat? sniff(Uint8List bytes) => ImageFormatRegistry.sniff(bytes);

  @override
  String toString() => 'ImageFormat.$name';
}

/// An inspectable [ImageFormat].
mixin InspectableFormat on ImageFormat {
  /// Reads metadata needed to preserve authored samples and colour meaning.
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes);
}

/// Isolate-local ordered collection of formats recognized by Imcodec.
///
/// Core formats are installed initially. Add-ons explicitly install and remove
/// their formats, so importing them alone cannot change signature detection.
abstract final class ImageFormatRegistry {
  /// Installed formats in signature-matching order.
  static final List<_ImageFormatRegistration> _registrations = [
    const _ImageFormatRegistration(format: ImageFormat.bmp),
    const _ImageFormatRegistration(format: ImageFormat.gif),
    const _ImageFormatRegistration(format: ImageFormat.png),
    const _ImageFormatRegistration(format: ImageFormat.jpeg),
    const _ImageFormatRegistration(format: ImageFormat.jpegXl),
    const _ImageFormatRegistration(format: ImageFormat.openExr),
    const _ImageFormatRegistration(format: ImageFormat.webp),
    const _ImageFormatRegistration(format: ImageFormat.qoi),
    const _ImageFormatRegistration(format: ImageFormat.tiff),
    const _ImageFormatRegistration(format: ImageFormat.tga, priority: -100),
  ];

  /// Installed formats as an immutable ordered snapshot.
  static List<ImageFormat> get formats => List.unmodifiable([
    for (final _ImageFormatRegistration registration in _registrations) registration.format,
  ]);

  /// Installs [format] according to its signature-matching [priority].
  ///
  /// Higher priorities are inspected first and equal priorities retain their
  /// registration order. Registering the same instance again is a no-op. A
  /// different instance cannot reuse an installed format name.
  static bool register(ImageFormat format, {int priority = 0}) {
    if (_indexOf(format) >= 0) {
      return false;
    }
    for (final _ImageFormatRegistration registration in _registrations) {
      if (registration.format.name == format.name) {
        throw ArgumentError.value(
          format.name,
          'format',
          'An image format with this name is already registered',
        );
      }
    }
    final _ImageFormatRegistration registration = _ImageFormatRegistration(
      format: format,
      priority: priority,
    );
    final int insertionIndex = _registrations.indexWhere(
      (candidate) => candidate.priority < priority,
    );
    if (insertionIndex < 0) {
      _registrations.add(registration);
    } else {
      _registrations.insert(insertionIndex, registration);
    }
    return true;
  }

  /// Removes [format], returning whether its exact instance was installed.
  static bool unregister(ImageFormat format) {
    final int index = _indexOf(format);
    if (index < 0) {
      return false;
    }
    _registrations.removeAt(index);
    return true;
  }

  /// Whether the exact [format] instance is currently installed.
  static bool contains(ImageFormat format) => _indexOf(format) >= 0;

  /// Finds an installed format by its stable [name].
  static ImageFormat? lookup(String name) {
    for (final _ImageFormatRegistration registration in _registrations) {
      if (registration.format.name == name) {
        return registration.format;
      }
    }
    return null;
  }

  /// Detects the first installed format whose signature matches [bytes].
  static ImageFormat? sniff(Uint8List bytes) {
    for (final _ImageFormatRegistration registration in _registrations) {
      if (registration.format.matches(bytes)) {
        return registration.format;
      }
    }
    return null;
  }

  /// Finds an installed format by identity rather than overridable equality.
  static int _indexOf(ImageFormat format) => _registrations.indexWhere(
    (registration) => identical(registration.format, format),
  );
}

/// One immutable entry carrying registry ordering separately from a format.
final class _ImageFormatRegistration {
  /// Format exposed by this entry.
  final ImageFormat format;

  /// Signature precedence relative to other entries.
  final int priority;

  /// Creates one ordered registry entry.
  const _ImageFormatRegistration({required this.format, this.priority = 0});
}

/// Finds a null terminator inside one bounded byte range.
int _zeroByte(Uint8List bytes, int start, int end) {
  for (int index = start; index < end; index++) {
    if (bytes[index] == 0) {
      return index;
    }
  }
  return -1;
}

/// Copies one container packet after enforcing its allocation limit.
Uint8List _boundedPacket(
  Uint8List source,
  int offset,
  int length, {
  required int maximumBytes,
  required String label,
}) {
  if (length > maximumBytes) {
    throw ImageCodecException('$label metadata exceeds the configured limit');
  }
  return Uint8List.fromList(
    Uint8List.sublistView(source, offset, offset + length),
  );
}

/// Ensures an encoded byte range lies inside its container.
void _ensureRange(Uint8List bytes, int offset, int length) {
  if (offset < 0 || length < 0 || offset > bytes.lengthInBytes - length) {
    throw const ImageCodecException(
      'An image metadata offset points outside the encoded data',
    );
  }
}

/// Compares one byte range with an ASCII literal.
bool _matchesAscii(Uint8List bytes, int offset, String value) {
  if (offset < 0 || offset > bytes.lengthInBytes - value.length) {
    return false;
  }
  for (int index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) {
      return false;
    }
  }
  return true;
}

/// Reads one unsigned little-endian twenty-four-bit integer.
int _littleUint24(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

/// Reads one unsigned little-endian thirty-two-bit integer.
int _littleUint32(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
