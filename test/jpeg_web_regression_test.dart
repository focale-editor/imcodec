import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks JPEG entropy decoding on VM, JavaScript and Dart WebAssembly runtimes.
void main() {
  test('baseline JPEG decodes the same coefficients on every runtime', () {
    // Varied content keeps long Huffman codes and many refills in flight;
    // bitwise operators work on 32 bits once compiled to JavaScript.
    final Image source = Image(width: 24, height: 16);
    for (int y = 0; y < 16; y++) {
      for (int x = 0; x < 24; x++) {
        source.setPixelRgba(x, y, x * 10, y * 15, (x * y * 7) % 256, 255);
      }
    }

    final Uint8List encoded = const JpegEncoder().encode(source, encodeOptions: const JpegEncodeOptions(quality: 100));
    final Image decoded = const JpegDecoder().decode(encoded);

    for (int offset = 0; offset < source.bytes.length; offset++) {
      expect(decoded.bytes[offset], closeTo(source.bytes[offset], 24), reason: 'byte $offset');
    }
  });
}
