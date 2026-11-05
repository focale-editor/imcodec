import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks arithmetic JBIG2 coding on VM, JavaScript and WebAssembly runtimes.
void main() {
  for (final bool prediction in [false, true]) {
    test('JBIG2 arithmetic contexts preserve all pixels, prediction $prediction', () {
      final Image source = Image(width: 139, height: 71);
      for (int y = 0; y < source.height; y++) {
        for (int x = 0; x < source.width; x++) {
          final int value = (x * 113 + y * 107 + x * y) % 19 < 8 ? 255 : 0;
          source.setPixelRgba(x, y, value, value, value, 255);
        }
      }
      final Uint8List encoded = encodeJbig2(source, options: Jbig2EncodeOptions(typicalPrediction: prediction));
      expect(decodeImage(encoded).bytes, source.bytes);
      expect(inspectImage(encoded)!.width, source.width);
      final Uint8List embedded = const Jbig2Encoder().encodeEmbedded(source);
      expect(const Jbig2Decoder().decodeEmbedded(embedded).bytes, source.bytes);
    });
  }
}
