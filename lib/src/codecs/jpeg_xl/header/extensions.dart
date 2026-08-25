import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl_limits.dart';

/// The `Extensions` bundle: 64 optional payloads gated by a bitmask key.
/// Payload contents are opaque; they are read and retained but not
/// interpreted.
final class Extensions {
  /// Stores the extensions key value used while processing JPEG XL data.
  ///
  final int extensionsKey;

  /// Stores the payloads state used internally by the JPEG XL codec.
  ///
  final List<Uint8List?> _payloads;

  /// Creates Extensions data for JPEG XL processing.
  ///
  const Extensions() : extensionsKey = 0, _payloads = const [];

  /// Processes read information in a JPEG XL codestream.
  ///
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

  /// Creates Extensions state for JPEG XL processing.
  ///
  const Extensions._({
    required this.extensionsKey,
    required this._payloads,
  });

  /// Processes int information in a JPEG XL codestream.
  ///
  Uint8List? operator [](int extId) => extId < _payloads.length ? _payloads[extId] : null;
}
