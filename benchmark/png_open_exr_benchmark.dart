import 'dart:io';
import 'dart:typed_data';

import 'package:imcodec/imcodec.dart';

/// Measures PNG compression presets and eight-bit OpenEXR conversion.
///
/// Compile with `dart compile exe benchmark/png_open_exr_benchmark.dart` for
/// AOT measurements. Optional arguments select an input photograph and the
/// number of measured runs, following two warm-up runs per operation.
void main(List<String> arguments) {
  final String path = arguments.isEmpty ? 'test/fixtures/photos/hubble.jpg' : arguments.first;
  final int runs = arguments.length < 2 ? 7 : int.parse(arguments[1]);
  if (runs < 1) {
    throw ArgumentError.value(runs, 'runs', 'Must be positive');
  }
  final Uint8List input = File(path).readAsBytesSync();
  final Image image = decodeImage(input);
  final List<(String, RasterCodec, RasterEncodeOptions)> cases = [
    ('PNG default', const PngCodec(), const PngEncodeOptions()),
    ('PNG fast', const PngCodec(), const PngEncodeOptions.fast()),
    ('OpenEXR uncompressed', const OpenExrCodec(), const OpenExrEncodeOptions(compression: OpenExrCompression.none)),
    ('OpenEXR ZIP', const OpenExrCodec(), const OpenExrEncodeOptions()),
  ];
  stdout.writeln('${image.width}x${image.height}, $runs measured runs');
  for (final (String label, RasterCodec codec, RasterEncodeOptions options) in cases) {
    final Uint8List reference = codec.encode(image, encodeOptions: options);
    codec.encode(image, encodeOptions: options);
    final List<int> times = [];
    int fingerprint = 0;
    for (int run = 0; run < runs; run++) {
      final Stopwatch watch = Stopwatch()..start();
      final Uint8List encoded = codec.encode(image, encodeOptions: options);
      watch.stop();
      times.add(watch.elapsedMicroseconds);
      if (encoded.length != reference.length) {
        throw StateError('$label produced inconsistent output lengths');
      }
      fingerprint ^= encoded[encoded.length ~/ 2];
    }
    times.sort();
    stdout.writeln('$label: ${(times[runs ~/ 2] / 1000).toStringAsFixed(2)} ms, ${reference.length} bytes, fingerprint $fingerprint');
  }
}
