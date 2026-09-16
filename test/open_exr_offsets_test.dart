import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';
import 'package:imcodec/src/codecs/open_exr/offsets_native.dart' if (dart.library.js_interop) 'package:imcodec/src/codecs/open_exr/offsets_web.dart' as platform;
import 'package:imcodec/src/codecs/open_exr/offsets_web.dart' as web;

/// Checks the Web adapter against exact bytes and the selected platform path.
void main() {
  test('offset words preserve unsigned boundaries and unaligned views', () {
    for (final int value in [0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000, 0x100000001, 0x123456789abcd, 0x1fffffffffffff]) {
      // Arrange. The reference uses arbitrary-precision arithmetic only here.
      final BigInt reference = BigInt.from(value);
      final List<int> expected = [for (int byte = 0; byte < 8; byte++) ((reference >> (byte * 8)) & BigInt.from(255)).toInt()];
      final Uint8List storage = Uint8List(16)..fillRange(0, 16, 0xa5);
      final ByteData data = ByteData.sublistView(storage, 2, 14);
      final ByteData platformData = ByteData(8);

      // Act.
      web.writeOffset(data, 1, value);
      platform.writeOffset(platformData, 0, value);

      // Assert, including untouched bytes around the unaligned view.
      expect(storage.sublist(3, 11), expected, reason: 'value=$value');
      expect(platformData.buffer.asUint8List(), expected);
      expect(storage.sublist(0, 3), everyElement(0xa5));
      expect(storage.sublist(11), everyElement(0xa5));
      expect(web.readOffset(data, 1, maxOffset: value), value);
      expect(platform.readOffset(platformData, 0, maxOffset: value), value);
      if (value > 0) {
        expect(() => web.readOffset(data, 1, maxOffset: value - 1), throwsA(isA<ImageCodecException>()));
        expect(() => platform.readOffset(platformData, 0, maxOffset: value - 1), throwsA(isA<ImageCodecException>()));
      }
    }
  });

  test('Web offsets reject values beyond exact integer precision', () {
    // Arrange.
    final ByteData data = ByteData(8)..setUint32(4, 0x200000, Endian.little);

    // Act and assert.
    expect(() => web.readOffset(data, 0, maxOffset: 0x20000000000000), throwsA(isA<ImageCodecException>()));
    expect(() => web.writeOffset(data, 0, 0x20000000000000), throwsRangeError);
    expect(() => web.writeOffset(data, 0, -1), throwsRangeError);
  });
}
