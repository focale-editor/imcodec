import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks that spreading the per-group work never changes the encoded bytes.
void main() {
  final List<(String, Image)> sources = <(String, Image)>[
    ('true color', decodePng(File('test/fixtures/png/p_rgb8i.expected.png').readAsBytesSync())),
    ('alpha', decodePng(File('test/fixtures/png/p_rgba8i.expected.png').readAsBytesSync())),
    ('palette', decodePng(File('test/fixtures/png/p_pal2.expected.png').readAsBytesSync())),
  ];

  for (final (String label, Image source) in sources) {
    test('a parallel encode of $label matches the sequential one', () async {
      for (final JpegXlEffort effort in JpegXlEffort.values) {
        final Uint8List sequential = encodeJpegXl(source, effort: effort);

        final Uint8List inline = await encodeJpegXlWith(runSequentially, source, effort: effort);
        final Uint8List isolated = await encodeJpegXlWith(onIsolates, source, effort: effort);
        final Uint8List pooled = await encodeJpegXlWith(onBoundedIsolates, source, effort: effort);

        expect(inline, sequential, reason: '$label ${effort.name} inline');
        expect(isolated, sequential, reason: '$label ${effort.name} isolates');
        expect(pooled, sequential, reason: '$label ${effort.name} pool');
        expect(decodeJpegXl(isolated).bytes, source.bytes, reason: '$label ${effort.name} round-trip');
      }
    });
  }

  test('the codec exposes the same parallel entry point', () async {
    final Image source = sources.first.$2;
    final JpegXlCodec codec = JpegXlCodec(effort: JpegXlEffort.fast);

    expect(await codec.encodeWith(onIsolates, source), codec.encode(source));
  });
}
