import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks decoding against files produced by independent encoders.
///
/// Every fixture is paired with an `.expected.png` holding the pixels a
/// reference decoder (libjpeg, libtiff, libwebp, or Pillow) produces, so a
/// regression in one codec cannot hide behind a matching regression in
/// another.
void main() {
  group('BMP conformance', () {
    _expectMatches('bmp', 'b_rle8b.bmp', 'eight-bit run-length encoding');
    _expectMatches('bmp', 'b_rle4.bmp', 'four-bit run-length encoding');
    _expectMatches('bmp', 'b_pal1.bmp', 'one-bit palette');
    _expectMatches('bmp', 'b_rgba32.bmp', 'thirty-two-bit bitfields with alpha');
    _expectMatches('bmp', 'b_16bit.bmp', 'sixteen-bit pixels', tolerance: 8);
  });

  group('TIFF conformance', () {
    _expectMatches('tiff', 't_bilevel.tif', 'bilevel samples');
    _expectMatches('tiff', 't_pal4.tif', 'four-bit palette');
    _expectMatches('tiff', 't_gray16.tif', 'sixteen-bit grayscale');
    _expectMatches('tiff', 't_rgb16.tif', 'sixteen-bit true color');
    _expectMatches('tiff', 't_pred.tif', 'compressed data with a horizontal predictor');
  });

  group('PNG conformance', () {
    _expectMatches('png', 'p_rgb8i.png', 'interlaced true color');
    _expectMatches('png', 'p_rgba8i.png', 'interlaced true color with alpha');
    _expectMatches('png', 'p_rgb16.png', 'sixteen-bit samples');
    _expectMatches('png', 'p_pal2.png', 'two-bit palette');
    _expectMatches('png', 'p_bw1.png', 'one-bit grayscale');
    _expectMatches('png', 'p_la8.png', 'grayscale with alpha');
    _expectMatches('png', 'p_trns_pal.png', 'palette transparency');
    _expectMatches('png', 'p_trns_gray.png', 'grayscale transparency');
  });

  group('WebP conformance', () {
    _expectMatches('webp', 'w_alpha.webp', 'lossless data with alpha');
    _expectMatches('webp', 'w_anim.webp', 'the first animation frame');
    _expectMatches('webp', 'w_lossy.webp', 'lossy data', tolerance: 2);
  });

  group('JPEG conformance', () {
    // The reference decoder applies a triangle filter when upsampling chroma,
    // so a subsampled fixture only matches within the shared rounding error of
    // the two inverse transforms.
    _expectMatches('jpeg', 'j420.jpg', 'four-two-zero chroma subsampling', tolerance: 3);
    _expectMatches('jpeg', 'j422.jpg', 'four-two-two chroma subsampling', tolerance: 3);
    _expectMatches('jpeg', 'j411.jpg', 'four-one-one chroma subsampling', tolerance: 3);
    _expectMatches('jpeg', 'jprog.jpg', 'progressive scans', tolerance: 3);
    _expectMatches('jpeg', 'jgray.jpg', 'a single grayscale component', tolerance: 3);
  });
}

/// Asserts that decoding `test/fixtures/[group]/[name]` matches its reference.
void _expectMatches(String group, String name, String description, {int tolerance = 0}) {
  test('decodes $description', () {
    final Uint8List encoded = File('test/fixtures/$group/$name').readAsBytesSync();
    final Image expected = decodePng(File('test/fixtures/$group/${name.substring(0, name.lastIndexOf('.'))}.expected.png').readAsBytesSync());

    final Image decoded = decodeImage(encoded);

    expect(decoded.width, expected.width, reason: name);
    expect(decoded.height, expected.height, reason: name);
    int worst = 0;
    for (int index = 0; index < expected.bytes.length; index++) {
      final int difference = (decoded.bytes[index] - expected.bytes[index]).abs();
      worst = difference > worst ? difference : worst;
    }
    expect(worst, lessThanOrEqualTo(tolerance), reason: '$name differs from its reference by $worst');
  });
}
