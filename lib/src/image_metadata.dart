import 'dart:typed_data';

import 'package:imcodec/src/decoded_image.dart';
import 'package:imcodec/src/formats/image_format.dart';
import 'package:imcodec/src/registry/registry.dart';

/// Default maximum number of decompressed ICC bytes retained from a container.
const int defaultMaxIccProfileBytes = 16 * 1024 * 1024;

/// Default maximum size of each retained EXIF, IPTC, or XMP packet.
const int defaultMaxDescriptiveMetadataBytes = 4 * 1024 * 1024;

/// Reads metadata needed to preserve authored samples and colour meaning.
///
/// `null` means the format has no metadata-aware reader yet. Pixel decoding is
/// deliberately separate so callers can keep a platform fast path for ordinary
/// untagged eight-bit images.
DecodedImageMetadata? inspectImage(
  Uint8List bytes, {
  int maxIccProfileBytes = defaultMaxIccProfileBytes,
  int maxDescriptiveMetadataBytes = defaultMaxDescriptiveMetadataBytes,
}) {
  if (maxIccProfileBytes < 1) {
    throw RangeError.range(
      maxIccProfileBytes,
      1,
      null,
      'maxIccProfileBytes',
    );
  }
  if (maxDescriptiveMetadataBytes < 1) {
    throw RangeError.range(
      maxDescriptiveMetadataBytes,
      1,
      null,
      'maxDescriptiveMetadataBytes',
    );
  }
  final ImageFormat? format = ImageFormat.sniff(bytes);
  if (format is InspectableFormat) {
    return format.inspect(
      bytes,
      maxIccProfileBytes,
      maxDescriptiveMetadataBytes,
    );
  }
  final ImageCodecExtension? extension = format == null ? null : ImageCodecRegistry.lookup(format);
  return extension?.supportsDecoding == true
      ? extension!.inspect(
          bytes,
          maxIccProfileBytes: maxIccProfileBytes,
          maxDescriptiveMetadataBytes: maxDescriptiveMetadataBytes,
        )
      : null;
}
