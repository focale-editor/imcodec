import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Builds a deterministic image containing gradients, edges, and transparency.
Image _createLossySource({int width = 31, int height = 19}) {
  final Image image = Image(width: width, height: height);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      image.setPixelRgba(
        x,
        y,
        (x * 7 + y * 3) & 0xff,
        (x * 2 + y * 11) & 0xff,
        ((x ~/ 5).isEven ? 220 : 35) + y,
        (x + 3 * y) % 13 == 0 ? (x * 17 + y * 9) & 0xff : 255,
      );
    }
  }
  return image;
}

/// Returns whether [encoded] contains a RIFF chunk named [fourCharacterCode].
bool _containsChunk(Uint8List encoded, String fourCharacterCode) {
  final List<int> expected = ascii.encode(fourCharacterCode);
  int offset = 12;
  while (offset + 8 <= encoded.length) {
    bool matches = true;
    for (int index = 0; index < 4; ++index) {
      matches = matches && encoded[offset + index] == expected[index];
    }
    if (matches) {
      return true;
    }
    final int length = encoded[offset + 4] | (encoded[offset + 5] << 8) | (encoded[offset + 6] << 16) | (encoded[offset + 7] << 24);
    offset += 8 + length + (length & 1);
  }
  return false;
}

/// Computes mean absolute RGB error while ignoring the separately coded alpha.
double _meanRgbError(Image first, Image second) {
  int total = 0;
  for (int offset = 0; offset < first.bytes.length; offset += 4) {
    for (int channel = 0; channel < 3; ++channel) {
      total += (first.bytes[offset + channel] - second.bytes[offset + channel]).abs();
    }
  }
  return total / (first.width * first.height * 3);
}

/// Verifies the public lossy WebP encoder contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encodes a VP8 key frame accepted by Flutter and preserves alpha', () async {
    final Image source = _createLossySource();

    final Uint8List encoded = encodeWebP(source, quality: 75);
    final Image decoded = decodeWebP(encoded);
    final ui.Codec flutterCodec = await ui.instantiateImageCodec(encoded);
    addTearDown(flutterCodec.dispose);
    final ui.FrameInfo flutterFrame = await flutterCodec.getNextFrame();
    addTearDown(flutterFrame.image.dispose);

    expect(ImageFormat.sniff(encoded), ImageFormat.webp);
    expect(_containsChunk(encoded, 'VP8 '), isTrue);
    expect(_containsChunk(encoded, 'VP8L'), isFalse);
    expect((decoded.width, decoded.height), (source.width, source.height));
    for (int offset = 3; offset < source.bytes.length; offset += 4) {
      expect(decoded.bytes[offset], source.bytes[offset]);
    }
    expect(_meanRgbError(source, decoded), lessThan(15));
    expect(
      (flutterFrame.image.width, flutterFrame.image.height),
      (source.width, source.height),
    );
  });

  test('higher quality reduces reconstruction error', () {
    final Image source = _createLossySource(width: 47, height: 35);

    final Image lowQuality = decodeWebP(encodeWebP(source, quality: 10));
    final Image highQuality = decodeWebP(
      encodeWebP(source, quality: 95, effort: WebPEffort.maximum),
    );
    final double highQualityError = _meanRgbError(source, highQuality);

    expect(highQualityError, lessThan(18));
    expect(
      highQualityError,
      lessThan(_meanRgbError(source, lowQuality)),
    );
  });

  test('maximum effort refines coefficients instead of matching balanced', () {
    final Image source = _createLossySource(width: 47, height: 35);
    final Uint8List balancedBytes = encodeWebP(
      source,
      quality: 75,
      effort: WebPEffort.balanced,
    );
    final Uint8List maximumBytes = encodeWebP(
      source,
      quality: 75,
      effort: WebPEffort.maximum,
    );
    final Image balanced = decodeWebP(balancedBytes);
    final Image maximum = decodeWebP(maximumBytes);

    expect(maximumBytes, isNot(balancedBytes));
    expect(
      _meanRgbError(source, maximum),
      lessThan(_meanRgbError(source, balanced)),
    );
  });

  for (final WebPEffort effort in WebPEffort.values) {
    test('${effort.name} effort produces a decodable image', () {
      final Image source = _createLossySource(width: 17, height: 9);

      final Uint8List encoded = WebPEncoder.lossy(
        quality: 70,
        effort: effort,
      ).encode(source);
      final Image decoded = const WebPDecoder().decode(
        encoded,
        maxPixels: 1000,
      );

      expect((decoded.width, decoded.height), (17, 9));
    });
  }

  test('quality is clamped and public entry points agree', () async {
    final Image source = _createLossySource(width: 13, height: 11);
    final Uint8List minimum = encodeWebP(source, quality: 0);
    final Uint8List maximum = encodeWebP(source, quality: 100);
    final Uint8List expected = encodeWebP(
      source,
      quality: 64,
      effort: WebPEffort.fast,
    );

    expect(encodeWebP(source, quality: -20), minimum);
    expect(encodeWebP(source, quality: 140), maximum);
    expect(
      encodeWebP(source, quality: 64, effort: WebPEffort.fast),
      expected,
    );
    expect(
      WebPCodec(
        quality: 64,
        effort: WebPEffort.fast,
      ).encode(source),
      expected,
    );
    expect(
      const WebPEncoder(
        quality: 64,
        effort: WebPEffort.fast,
      ).encode(source),
      expected,
    );
    expect(
      encodeImage(
        source,
        format: ImageFormat.webp,
        webPQuality: 64,
        webPEffort: WebPEffort.fast,
      ),
      expected,
    );
    expect(
      await encodeWebPWith(
        runSequentially,
        source,
        quality: 64,
        effort: WebPEffort.fast,
      ),
      expected,
    );
    expect(
      await encodeImageWith(
        runSequentially,
        source,
        format: ImageFormat.webp,
        webPQuality: 64,
        webPEffort: WebPEffort.fast,
      ),
      expected,
    );
  });

  test('the default WebP entry point remains lossless', () {
    final Image source = _createLossySource(width: 5, height: 3);

    final Uint8List encoded = encodeWebP(source);

    expect(_containsChunk(encoded, 'VP8L'), isTrue);
    expect(decodeWebP(encoded).bytes, source.bytes);
  });
}
