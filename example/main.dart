import 'dart:developer';
import 'dart:typed_data';

import 'package:imcodec/imcodec.dart' as img;

/// Encodes a small RGBA image as PNG, then decodes it again.
/// Run this from a Flutter application, where Flutter's platform image codecs
/// are available for PNG decoding.
Future<void> main() async {
  final Uint8List rgba = Uint8List.fromList([
    255,
    0,
    0,
    255,
    0,
    255,
    0,
    255,
    0,
    0,
    255,
    255,
    255,
    255,
    255,
    128,
  ]);
  final img.Image source = img.Image.fromRgba(
    width: 2,
    height: 2,
    bytes: rgba,
  );

  final Uint8List encoded = img.encodePng(source);
  final img.Image decoded = img.decodeImage(encoded);

  log(
    'Encoded ${source.width} × ${source.height} pixels into '
    '${encoded.lengthInBytes} PNG bytes; decoded ${decoded.width} × '
    '${decoded.height} pixels.',
    name: 'imcodec.example',
  );
}
