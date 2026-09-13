import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

void main() {
  test('GIF round-trips a static palette and binary transparency', () async {
    final Image source = Image(width: 4, height: 2)
      ..setPixelRgb(0, 0, 255, 0, 0)
      ..setPixelRgb(1, 0, 0, 255, 0)
      ..setPixelRgb(2, 0, 0, 0, 255)
      ..setPixelRgba(3, 0, 255, 255, 255, 0)
      ..setPixelRgb(0, 1, 0, 0, 255)
      ..setPixelRgb(1, 1, 0, 255, 0)
      ..setPixelRgb(2, 1, 255, 0, 0)
      ..setPixelRgba(3, 1, 0, 0, 0, 0);

    final Uint8List encoded = encodeGif(
      source,
      options: const GifEncodeOptions(
        colorCount: 4,
        ditherAmount: 0,
      ),
    );
    final Image decoded = decodeImage(encoded);

    expect(ImageFormat.sniff(encoded), ImageFormat.gif);
    expect(String.fromCharCodes(encoded.take(6)), 'GIF89a');
    expect(decoded.width, source.width);
    expect(decoded.height, source.height);
    expect(decoded.alpha(3, 0), 0);
    expect(decoded.alpha(3, 1), 0);
    expect(decoded.bytes.sublist(0, 12), source.bytes.sublist(0, 12));
    await _expectFlutterAccepts(encoded, width: 4, height: 2);
  });

  test('GIF LZW writes the end code at the width the decoder reads it with', () async {
    // Small images with few colours end exactly where the decoder widens its
    // codes; an end code written one bit too narrow reads as a missing one.
    const List<List<int>> palette = [
      [0, 0, 0, 0],
      [255, 0, 0, 255],
      [0, 255, 0, 255],
      [0, 0, 255, 255],
    ];
    int seed = 1;
    int nextRandom(int bound) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % bound;
    }

    int flutterChecks = 0;
    for (int trial = 0; trial < 4000; trial++) {
      final int width = 1 + nextRandom(12);
      final int height = 1 + nextRandom(6);
      final int colours = 1 + nextRandom(palette.length);
      final Image source = Image(width: width, height: height);
      for (int index = 0; index < width * height; index++) {
        source.bytes.setAll(index * 4, palette[nextRandom(colours)]);
      }

      final Uint8List encoded = encodeGif(
        source,
        options: const GifEncodeOptions(ditherAmount: 0),
      );

      expect(decodeImage(encoded).bytes, source.bytes, reason: '${width}x$height trial $trial');
      if (trial % 40 == 0) {
        await _expectFlutterAccepts(encoded, width: width, height: height);
        flutterChecks++;
      }
    }
    expect(flutterChecks, 100);
  });

  test('GIF LZW grows its dictionary without changing decoded pixels', () {
    final Image source = Image(width: 257, height: 97);
    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        source.setPixelRgb(
          x,
          y,
          x * 17 + y * 13 & 0xff,
          x * 7 + y * 29 & 0xff,
          x * 31 + y * 3 & 0xff,
        );
      }
    }

    final Uint8List encoded = encodeGif(
      source,
      options: const GifEncodeOptions(
        colorCount: 64,
        ditherAmount: 0,
        transparency: false,
      ),
    );
    final Image decoded = decodeGif(encoded);

    expect(decoded.width, source.width);
    expect(decoded.height, source.height);
    expect(decoded.bytes.toSet().length, greaterThan(16));
  });

  test('GIF decoder accepts an independently assembled one-pixel stream', () {
    final Uint8List fixture = Uint8List.fromList([
      ...'GIF89a'.codeUnits,
      1,
      0,
      1,
      0,
      0x80,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
      0x2c,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      0x44,
      0x01,
      0,
      0x3b,
    ]);

    final Image decoded = decodeGif(fixture);

    expect(decoded.width, 1);
    expect(decoded.height, 1);
    expect(decoded.bytes, [0, 0, 0, 255]);
  });
}

/// Verifies that Flutter's platform decoder accepts [bytes].
Future<void> _expectFlutterAccepts(
  Uint8List bytes, {
  required int width,
  required int height,
}) async {
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    bytes,
  );
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    image = frame.image;
    expect(image.width, width);
    expect(image.height, height);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
