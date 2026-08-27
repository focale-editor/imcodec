import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Exercises BMP, TGA, and QOI import and export.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BMP', () {
    test('round-trips alpha exactly and is accepted by Flutter', () async {
      final Image source = _testImage();

      final Uint8List encoded = encodeBmp(source);
      final Image decoded = decodeBmp(encoded);
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(buffer);

      expect(ImageFormat.sniff(encoded), ImageFormat.bmp);
      expect(decoded.bytes, source.bytes);
      expect(descriptor.width, source.width);
      expect(descriptor.height, source.height);
      descriptor.dispose();
      buffer.dispose();
    });

    test('decodes an independent bottom-up 24-bit fixture', () {
      final Image decoded = decodeBmp(_bmp24Fixture);

      expect(decoded.width, 2);
      expect(decoded.height, 2);
      expect(decoded.bytes, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]);
    });

    test('decodes an independent indexed fixture', () {
      final Image decoded = decodeBmp(_bmpIndexedFixture);

      expect(decoded.bytes, [255, 0, 0, 255]);
    });
  });

  group('TGA', () {
    test('round-trips raw and run-length encoded RGBA', () {
      final Image source = _testImage();

      final Uint8List raw = encodeTga(source, runLengthEncoding: false);
      final Uint8List compressed = encodeTga(source);

      expect((decodeTga(raw)).bytes, source.bytes);
      expect((decodeTga(compressed)).bytes, source.bytes);
      expect(ImageFormat.sniff(raw), ImageFormat.tga);
      expect(ImageFormat.sniff(compressed), ImageFormat.tga);
    });

    test('decodes an independent bottom-left 24-bit fixture', () {
      final Image decoded = decodeTga(_tga24Fixture);

      expect(decoded.width, 2);
      expect(decoded.height, 2);
      expect(decoded.bytes, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]);
    });

    test('decodes an independent grayscale RLE packet', () {
      final Image decoded = decodeTga(_tgaGrayscaleRleFixture);

      expect(decoded.bytes, [127, 127, 127, 255, 127, 127, 127, 255, 127, 127, 127, 255]);
    });

    test('decodes an independent color-mapped fixture', () {
      final Image decoded = decodeTga(_tgaIndexedFixture);

      expect(decoded.bytes, [255, 0, 0, 255, 0, 0, 0, 255]);
    });
  });

  group('QOI', () {
    test('round-trips RGBA exactly', () {
      final Image source = _testImage();

      final Uint8List encoded = encodeQoi(source);
      final Image decoded = decodeQoi(encoded);

      expect(ImageFormat.sniff(encoded), ImageFormat.qoi);
      expect(decoded.bytes, source.bytes);
    });

    test('encodes the canonical one-pixel RGB stream', () {
      final Image red = Image(width: 1, height: 1)..setPixelRgba(0, 0, 255, 0, 0, 255);

      final Uint8List encoded = encodeQoi(red);

      expect(encoded, [0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0, 0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
    });

    test('decodes an independent one-pixel RGB stream', () {
      final Image decoded = decodeQoi(_qoiRedFixture);

      expect(decoded.bytes, [255, 0, 0, 255]);
    });

    test('decodes independent run, diff, luma, alpha, and index opcodes', () {
      final Image decoded = decodeQoi(_qoiOpcodeFixture);

      expect(decoded.bytes, [0, 0, 0, 255, 1, 1, 1, 255, 5, 10, 4, 255, 5, 10, 4, 128, 0, 0, 0, 255]);
    });
  });

  test('new codecs round-trip random pixels across packet boundaries', () {
    final math.Random random = math.Random(271828);
    for (final (int width, int height) in [(1, 1), (1, 129), (129, 1), (17, 9)]) {
      final Uint8List pixels = Uint8List.fromList(List<int>.generate(width * height * 4, (_) => random.nextInt(256)));
      final Image source = Image.fromRgba(width: width, height: height, bytes: pixels);

      expect((decodeBmp(encodeBmp(source))).bytes, source.bytes);
      expect((decodeTga(encodeTga(source))).bytes, source.bytes);
      expect((decodeQoi(encodeQoi(source))).bytes, source.bytes);
    }
  });

  test('automatic dispatch decodes every new format', () {
    final Image source = _testImage();
    final List<Uint8List> encodedImages = [encodeBmp(source), encodeTga(source), encodeQoi(source)];

    for (final Uint8List encoded in encodedImages) {
      final Image decoded = decodeImage(encoded);
      expect(decoded.bytes, source.bytes);
    }
  });

  test('pure-Dart decoders enforce pixel limits and reject truncation', () {
    final Image source = _testImage();

    expect(() => decodeBmp(encodeBmp(source), maxPixels: 1), throwsA(isA<ImageCodecException>()));
    expect(() => decodeTga(Uint8List.sublistView(encodeTga(source), 0, 19)), throwsA(isA<ImageCodecException>()));
    expect(() => decodeQoi(Uint8List.sublistView(encodeQoi(source), 0, 15)), throwsA(isA<ImageCodecException>()));
  });
}

/// Creates pixels covering opaque, translucent, and invisible colors.
Image _testImage() => Image.fromRgba(
  width: 4,
  height: 2,
  bytes: Uint8List.fromList([255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 12, 34, 56, 78, 250, 240, 230, 220, 128, 64, 32, 16, 128, 64, 32, 16]),
);

/// Stores an independently constructed bottom-up 24-bit BMP image.
final Uint8List _bmp24Fixture = Uint8List.fromList([
  0x42,
  0x4d,
  70,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  54,
  0,
  0,
  0,
  40,
  0,
  0,
  0,
  2,
  0,
  0,
  0,
  2,
  0,
  0,
  0,
  1,
  0,
  24,
  0,
  0,
  0,
  0,
  0,
  16,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  255,
  0,
  0,
  255,
  255,
  255,
  0,
  0,
  0,
  0,
  255,
  0,
  255,
  0,
  0,
  0,
]);

/// Stores an independently constructed indexed BMP image.
final Uint8List _bmpIndexedFixture = Uint8List.fromList([
  0x42,
  0x4d,
  66,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  62,
  0,
  0,
  0,
  40,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  0,
  8,
  0,
  0,
  0,
  0,
  0,
  4,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  2,
  0,
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
  255,
  0,
  1,
  0,
  0,
  0,
]);

/// Stores an independently constructed bottom-left 24-bit TGA image.
final Uint8List _tga24Fixture = Uint8List.fromList([
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
  2,
  0,
  2,
  0,
  24,
  0,
  255,
  0,
  0,
  255,
  255,
  255,
  0,
  0,
  255,
  0,
  255,
  0,
]);

/// Stores an independently constructed grayscale TGA run-length packet.
final Uint8List _tgaGrayscaleRleFixture = Uint8List.fromList([
  0,
  0,
  11,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  3,
  0,
  1,
  0,
  8,
  0x20,
  0x82,
  127,
]);

/// Stores an independently constructed color-mapped TGA image.
final Uint8List _tgaIndexedFixture = Uint8List.fromList([
  0,
  1,
  1,
  0,
  0,
  2,
  0,
  24,
  0,
  0,
  0,
  0,
  2,
  0,
  1,
  0,
  8,
  0x20,
  0,
  0,
  0,
  0,
  0,
  255,
  1,
  0,
]);

/// Stores the canonical QOI stream for one opaque red pixel.
final Uint8List _qoiRedFixture = Uint8List.fromList([0x71, 0x6f, 0x69, 0x66, 0, 0, 0, 1, 0, 0, 0, 1, 3, 0, 0xfe, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);

/// Stores QOI operations covering every stateful decoding path.
final Uint8List _qoiOpcodeFixture = Uint8List.fromList([
  0x71,
  0x6f,
  0x69,
  0x66,
  0,
  0,
  0,
  5,
  0,
  0,
  0,
  1,
  4,
  0,
  0xc0,
  0x7f,
  0xa9,
  0x32,
  0xff,
  5,
  10,
  4,
  128,
  0x35,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
]);
