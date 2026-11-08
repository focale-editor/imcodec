import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

void main() {
  for (final int count in [2, 4, 16, 32]) {
    test('libwebp palette $count expands packed rows to the declared width', () {
      final Image image = decodeWebP(File('test/fixtures/webp_palette/palette$count.webp').readAsBytesSync());
      expect(image.width, 37);
      expect(image.height, 35);
      expect(image.bytes, File('test/fixtures/webp_palette/palette$count.rgba').readAsBytesSync());
    });
  }
}
