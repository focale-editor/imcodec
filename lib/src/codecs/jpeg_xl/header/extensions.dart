import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/limits.dart';

/// The `Extensions` bundle: 64 optional payloads gated by a bitmask key.
/// Payload contents are opaque; they are read and retained but not
/// interpreted.
final class Extensions {
  /// Bit mask identifying extension payloads present in the header.
  final int extensionsKey;

  /// Opaque payload indexed by extension identifier.
  final List<Uint8List?> _payloads;

  /// Creates an empty extension bundle.
  const Extensions() : extensionsKey = 0, _payloads = const [];

  /// Reads this structure from the bitstream.
  factory Extensions.read({
    required BitReader reader,
  }) {
    final int extensionsKey = reader.readU64();
    final lengths = List<int>.filled(64, -1);
    for (var i = 0; i < 64; i++) {
      if ((1 << i) & extensionsKey != 0) {
        final int length = reader.readU64();
        if (length < 0 || length > JpegXlLimits.maxExtensionBytes) {
          throw const JpegXlInvalidBitstreamException(message: 'extension payload too large');
        }
        lengths[i] = length;
      }
    }
    final payloads = List<Uint8List?>.filled(64, null);
    for (var i = 0; i < 64; i++) {
      final int length = lengths[i];
      if (length >= 0) {
        final buf = Uint8List(length);
        for (var j = 0; j < length; j++) {
          buf[j] = reader.readBits(8);
        }
        payloads[i] = buf;
      }
    }
    return Extensions._(extensionsKey: extensionsKey, payloads: payloads);
  }

  /// Creates a decoded extension bundle.
  const Extensions._({
    required this.extensionsKey,
    required this._payloads,
  });

  /// Returns the payload for [extensionIdentifier], when present.
  Uint8List? operator [](int extensionIdentifier) => extensionIdentifier < _payloads.length ? _payloads[extensionIdentifier] : null;
}
