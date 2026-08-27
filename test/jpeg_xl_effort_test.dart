import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks that every JPEG XL effort level stays lossless and stays ordered.
void main() {
  final List<(String, Image)> sources = <(String, Image)>[
    ('true color', decodePng(File('test/fixtures/png/p_rgb8i.expected.png').readAsBytesSync())),
    ('alpha', decodePng(File('test/fixtures/png/p_rgba8i.expected.png').readAsBytesSync())),
    ('palette', decodePng(File('test/fixtures/png/p_pal2.expected.png').readAsBytesSync())),
    ('bilevel', decodePng(File('test/fixtures/png/p_bw1.expected.png').readAsBytesSync())),
  ];

  for (final (String label, Image source) in sources) {
    test('every effort level round-trips $label losslessly', () {
      for (final JpegXlEffort effort in JpegXlEffort.values) {
        final Uint8List encoded = encodeJpegXl(source, effort: effort);

        expect(ImageFormat.sniff(encoded), ImageFormat.jpegXl, reason: '$label ${effort.name}');
        expect(decodeJpegXl(encoded).bytes, source.bytes, reason: '$label ${effort.name}');
      }
    });
  }

  test('higher effort never produces a larger file', () {
    for (final (String label, Image source) in sources) {
      final int fast = encodeJpegXl(source, effort: JpegXlEffort.fast).length;
      final int balanced = encodeJpegXl(source, effort: JpegXlEffort.balanced).length;
      final int maximum = encodeJpegXl(source, effort: JpegXlEffort.maximum).length;

      expect(balanced, lessThanOrEqualTo(fast), reason: '$label balanced');
      expect(maximum, lessThanOrEqualTo(balanced), reason: '$label maximum');
    }
  });

  test('the codec and the encoder both accept an effort level', () {
    final Image source = sources.first.$2;

    final Uint8List viaCodec = JpegXlCodec(effort: JpegXlEffort.fast).encode(source);
    final Uint8List viaEncoder = const JpegXlEncoder(effort: JpegXlEffort.fast).encode(source);

    expect(viaCodec, viaEncoder);
    expect(decodeJpegXl(viaCodec).bytes, source.bytes);
  });
}
