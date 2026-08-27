import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Exercises the codecs on real photographs rather than synthetic patterns.
///
/// Real content has the run lengths, colour counts, and frequency spectrum the
/// codecs are tuned for, so it catches size and correctness regressions that
/// generated test patterns hide. See `test/fixtures/photos/ATTRIBUTION.md`.
void main() {
  final List<(String, Image)> photos = <(String, Image)>[
    ('hubble', decodeJpg(File('test/fixtures/photos/hubble.jpg').readAsBytesSync())),
    ('earth', decodeJpg(File('test/fixtures/photos/earth.jpg').readAsBytesSync())),
    ('transparency', decodePng(File('test/fixtures/photos/transparency.png').readAsBytesSync())),
  ];
  final List<(String, Image, (int, int))> additionalPhotos = <(String, Image, (int, int))>[
    ('snowy mountain', decodeJpg(File('test/fixtures/photos/snowy_mountain.jpg').readAsBytesSync()), (1280, 853)),
    ('cheetah', decodeJpg(File('test/fixtures/photos/cheetah.jpg').readAsBytesSync()), (1200, 1200)),
    ('James Lovell', decodePng(File('test/fixtures/photos/james_lovell.png').readAsBytesSync()), (580, 1058)),
    ('grinding machine', decodeWebP(File('test/fixtures/photos/grinding_machine.webp').readAsBytesSync()), (640, 459)),
    ('dark inside', decodeWebP(File('test/fixtures/photos/dark_inside.webp').readAsBytesSync()), (720, 1280)),
  ];

  test('the fixtures decode to the sizes their sources declare', () {
    expect((photos[0].$2.width, photos[0].$2.height), (1280, 1335));
    expect((photos[1].$2.width, photos[1].$2.height), (1280, 1281));
    expect((photos[2].$2.width, photos[2].$2.height), (800, 600));
  });

  test('the transparency fixture really carries alpha', () {
    final Uint8List bytes = photos[2].$2.bytes;
    bool translucent = false;
    for (int offset = 3; offset < bytes.length && !translucent; offset += 4) {
      translucent = bytes[offset] != 255;
    }

    expect(translucent, isTrue);
  });

  test('the additional Wikimedia fixtures decode at their declared sizes', () {
    for (final (String label, Image photo, (int, int) size) in additionalPhotos) {
      expect((photo.width, photo.height), size, reason: label);
    }
  });

  for (final (String label, Image photo, _) in additionalPhotos) {
    test('JPEG XL fast round-trips the additional $label fixture', () {
      final Uint8List encoded = encodeJpegXl(photo, effort: JpegXlEffort.fast);

      expect(decodeJpegXl(encoded).bytes, photo.bytes);
    });
  }

  for (final (String label, Image photo) in photos) {
    test('lossless codecs round-trip $label exactly', () {
      expect(decodePng(encodePng(photo)).bytes, photo.bytes, reason: 'PNG');
      expect(decodeQoi(encodeQoi(photo)).bytes, photo.bytes, reason: 'QOI');
      expect(decodeBmp(encodeBmp(photo)).bytes, photo.bytes, reason: 'BMP');
      expect(decodeTga(encodeTga(photo)).bytes, photo.bytes, reason: 'TGA');
      expect(decodeTiff(encodeTiff(photo)).bytes, photo.bytes, reason: 'TIFF');
      expect(decodeWebP(encodeWebP(photo)).bytes, photo.bytes, reason: 'WebP');
      expect(decodeJpegXl(encodeJpegXl(photo, effort: JpegXlEffort.fast)).bytes, photo.bytes, reason: 'JPEG XL');
    });

    test('JPEG survives a round-trip of $label with a small error', () {
      final Image decoded = decodeJpg(encodeJpg(photo, quality: 95));

      expect(decoded.width, photo.width);
      expect(decoded.height, photo.height);
      int total = 0;
      for (int pixel = 0; pixel < photo.width * photo.height; pixel++) {
        final int alpha = photo.bytes[pixel * 4 + 3];
        for (int channel = 0; channel < 3; channel++) {
          // JPEG has no alpha, so the encoder composites against white; the
          // reference has to be composited the same way to be comparable.
          final int expected = (photo.bytes[pixel * 4 + channel] * alpha + 255 * (255 - alpha) + 127) ~/ 255;
          total += (decoded.bytes[pixel * 4 + channel] - expected).abs();
        }
      }
      // Quality 95 keeps the mean absolute error well under one step per
      // channel on photographic content.
      expect(total / (photo.width * photo.height * 3), lessThan(2.5), reason: label);
    });
  }
}
