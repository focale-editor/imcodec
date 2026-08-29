import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

void main() {
  group('Image', () {
    test('normalizes row-strided BGRA input', () {
      final Uint8List source = Uint8List.fromList([30, 20, 10, 40, 60, 50, 40, 70, 0, 0, 0, 0]);

      final Image image = Image.fromBytes(width: 2, height: 1, bytes: source.buffer, numChannels: 4, rowStride: 12, order: ChannelOrder.bgra);

      expect(image.bytes, [10, 20, 30, 40, 40, 50, 60, 70]);
    });

    test('rejects a short source buffer', () {
      final Uint8List source = Uint8List(3);

      expect(() => Image.fromBytes(width: 1, height: 1, bytes: source.buffer, numChannels: 4), throwsA(isA<ImageCodecException>()));
    });
  });

  test('format detection recognizes every supported signature', () {
    expect(ImageFormat.sniff(Uint8List.fromList([0x42, 0x4d])), ImageFormat.bmp);
    expect(
      ImageFormat.sniff(Uint8List.fromList('GIF89a'.codeUnits)),
      ImageFormat.gif,
    );
    expect(ImageFormat.sniff(Uint8List.fromList([0xff, 0xd8, 0xff])), ImageFormat.jpeg);
    expect(ImageFormat.sniff(Uint8List.fromList([0xff, 0x0a])), ImageFormat.jpegXl);
    expect(ImageFormat.sniff(Uint8List.fromList([0x00, 0x00, 0x00, 0x0c, 0x4a, 0x58, 0x4c, 0x20, 0x0d, 0x0a, 0x87, 0x0a])), ImageFormat.jpegXl);
    expect(ImageFormat.sniff(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), ImageFormat.png);
    expect(ImageFormat.sniff(Uint8List.fromList([0x71, 0x6f, 0x69, 0x66])), ImageFormat.qoi);
    expect(ImageFormat.sniff(_uncompressedTgaFixture), ImageFormat.tga);
    expect(ImageFormat.sniff(Uint8List.fromList([0x49, 0x49, 0x2a, 0x00])), ImageFormat.tiff);
    expect(ImageFormat.sniff(Uint8List.fromList([0x4d, 0x4d, 0x00, 0x2a])), ImageFormat.tiff);
    expect(ImageFormat.sniff(Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])), ImageFormat.webp);
    expect(ImageFormat.sniff(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });
}

final Uint8List _uncompressedTgaFixture = Uint8List.fromList([
  0,
  0,
  2,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  1,
  0,
  24,
  0,
  0,
  0,
  255,
]);
