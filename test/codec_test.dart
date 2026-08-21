import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PNG round-trips RGBA pixels through Flutter', () async {
    final Image source = testImage();

    final Uint8List encoded = encodePng(source);
    final Image decoded = await decodePng(encoded);

    expect(ImageFormat.sniff(encoded), ImageFormat.png);
    expectFlutterRgbaClose(decoded, source);
  });

  test('JPEG encodes, decodes, and composites transparency', () async {
    final Image source = Image(width: 2, height: 1)
      ..setPixelRgba(0, 0, 255, 0, 0, 255)
      ..setPixelRgba(1, 0, 0, 0, 0, 0);

    final Uint8List encoded = encodeJpg(source, quality: 100);
    final Image decoded = await decodeJpg(encoded);

    expect(ImageFormat.sniff(encoded), ImageFormat.jpeg);
    expect(decoded.red(0, 0), greaterThan(200));
    expect(decoded.bytes.sublist(4, 7), everyElement(greaterThan(220)));
  });

  test('WebP round-trips RGBA pixels through Flutter', () async {
    final Image source = testImage();

    final Uint8List encoded = encodeWebP(source);
    final Image decoded = await decodeWebP(encoded);

    expect(ImageFormat.sniff(encoded), ImageFormat.webp);
    expectFlutterRgbaClose(decoded, source);
  });

  test('lossless codecs handle varied dimensions and alpha', () async {
    final math.Random random = math.Random(314159);
    for (final (int width, int height) in [(1, 1), (1, 7), (7, 1), (31, 33), (33, 35)]) {
      final Uint8List pixels = Uint8List.fromList(List<int>.generate(width * height * 4, (_) => random.nextInt(256)));
      final Image source = Image.fromRgba(width: width, height: height, bytes: pixels);

      final Image png = await decodePng(encodePng(source));
      final Image webp = await decodeWebP(encodeWebP(source));

      expectFlutterRgbaClose(png, source);
      expectFlutterRgbaClose(webp, source);
    }
  });

  test('synchronous encoders run in a worker isolate', () async {
    final Uint8List pixels = Uint8List.fromList(testImage().bytes);

    final List<ImageFormat?> formats = await Isolate.run(() {
      final Image image = Image.fromRgba(width: 3, height: 2, bytes: pixels, copy: false);
      return [
        ImageFormat.sniff(encodeBmp(image)),
        ImageFormat.sniff(encodeJpg(image)),
        ImageFormat.sniff(encodePng(image)),
        ImageFormat.sniff(encodeQoi(image)),
        ImageFormat.sniff(encodeTga(image)),
        ImageFormat.sniff(encodeWebP(image)),
      ];
    });

    expect(formats, ImageFormat.values);
  });
}

Image testImage() => Image.fromRgba(
  width: 3,
  height: 2,
  bytes: Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 12, 34, 56, 78, 250, 240, 230, 220, 128, 64, 32, 16]),
);

void expectFlutterRgbaClose(Image actual, Image expected) {
  expect(actual.width, expected.width);
  expect(actual.height, expected.height);
  for (int offset = 0; offset < expected.bytes.length; offset += 4) {
    final int alpha = expected.bytes[offset + 3];
    expect(actual.bytes[offset + 3], alpha, reason: 'alpha at pixel ${offset ~/ 4}');
    if (alpha == 0) {
      continue;
    }
    final int tolerance = (255 / alpha).ceil();
    for (int channel = 0; channel < 3; channel++) {
      expect(actual.bytes[offset + channel], closeTo(expected.bytes[offset + channel], tolerance), reason: 'channel $channel at pixel ${offset ~/ 4}');
    }
  }
}
