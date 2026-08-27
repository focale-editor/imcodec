import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Exercises the public JPEG XL codec behavior.
void main() {
  group('JPEG XL', () {
    test('round-trips lossless RGBA exactly', () {
      final Image source = _testImage();

      final Uint8List encoded = encodeJpegXl(source);
      final Image decoded = decodeJpegXl(encoded);

      expect(ImageFormat.sniff(encoded), ImageFormat.jpegXl);
      expect(decoded.width, source.width);
      expect(decoded.height, source.height);
      expect(decoded.bytes, source.bytes);
    });

    test('decodes an independently encoded lossy VarDCT fixture', () {
      final Uint8List encoded = File('test/fixtures/jpeg_xl/screentone_256_d0_e5.jxl').readAsBytesSync();

      final Image decoded = decodeJxl(encoded);

      expect(decoded.width, 256);
      expect(decoded.height, 256);
      expect(decoded.bytes.take(16), [96, 96, 96, 255, 96, 96, 96, 255, 96, 96, 96, 255, 255, 255, 255, 255]);
      expect(_fnv1a(decoded.bytes), 529052100);
    });

    test('automatic dispatch decodes JPEG XL', () {
      final Image source = _testImage();

      final Image decoded = decodeImage(encodeJxl(source));

      expect(decoded.bytes, source.bytes);
    });

    test('enforces pixel limits and rejects truncation', () {
      final Uint8List encoded = encodeJxl(_testImage());

      expect(() => decodeJxl(encoded, maxPixels: 1), throwsA(isA<ImageCodecException>()));
      expect(
        () => decodeJxl(Uint8List.sublistView(encoded, 0, 3)),
        throwsA(isA<ImageCodecException>()),
      );
    });
  });
}

/// Creates pixels covering opaque, translucent, and invisible colors.
Image _testImage() => Image.fromRgba(
  width: 4,
  height: 2,
  bytes: Uint8List.fromList([255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 12, 34, 56, 78, 250, 240, 230, 220, 128, 64, 32, 16, 128, 64, 32, 16]),
);

/// Computes the unsigned 32-bit FNV-1a checksum used by the fixture gate.
int _fnv1a(Uint8List bytes) {
  int hash = 2166136261;
  for (final int byte in bytes) {
    hash = ((hash ^ byte) * 16777619) & 0xffffffff;
  }
  return hash;
}
