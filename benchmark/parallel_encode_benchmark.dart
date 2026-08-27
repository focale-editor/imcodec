import 'dart:io';
import 'dart:typed_data';

import 'package:imcodec/imcodec.dart';

/// Records parallel batches while running at most four jobs concurrently.
final class _BenchmarkRunner {
  /// Number of batches offered by the encoder.
  int batchCount = 0;

  /// Runs one batch on at most four isolates.
  Future<List<R>> call<T, R>(
    List<T> inputs,
    R Function(T input) task,
  ) {
    batchCount++;
    return onBoundedIsolates(inputs, task, limit: 4);
  }
}

/// Compares sequential and isolate-backed encoding on a real photograph.
Future<void> main(List<String> arguments) async {
  final String imagePath = arguments.isEmpty ? 'test/fixtures/photos/hubble.jpg' : arguments.first;
  final int iterations = arguments.length < 2 ? 3 : int.parse(arguments[1]);
  final Uint8List encodedSource = File(imagePath).readAsBytesSync();
  final Image image = imagePath.toLowerCase().endsWith('.png') ? PngCodec().decode(encodedSource) : JpegCodec().decode(encodedSource);
  final List<(String, RasterCodec)> codecs = <(String, RasterCodec)>[
    ('JPEG 4:4:4', JpegCodec(quality: 90)),
    ('JPEG 4:2:0', JpegCodec(quality: 90, chroma: JpegChroma.yuv420)),
    ('PNG', PngCodec(level: 6)),
    ('BMP', const BmpCodec()),
    ('QOI', const QoiCodec()),
    ('TGA', TgaCodec()),
    ('TIFF PackBits', TiffCodec()),
    ('WebP', const WebPCodec()),
  ];

  stdout.writeln('${image.width}x${image.height}, $iterations measured iteration(s)');
  for (final (String label, RasterCodec codec) in codecs) {
    final _BenchmarkRunner runner = _BenchmarkRunner();
    final Uint8List expected = codec.encode(image);
    final Uint8List warmParallel = await codec.encodeWith(runner.call, image);
    if (!_equalBytes(expected, warmParallel)) {
      throw StateError('$label produced different bytes in parallel.');
    }

    final List<int> sequentialTimes = <int>[];
    final List<int> parallelTimes = <int>[];
    for (int iteration = 0; iteration < iterations; iteration++) {
      final Stopwatch sequentialWatch = Stopwatch()..start();
      codec.encode(image);
      sequentialWatch.stop();
      sequentialTimes.add(sequentialWatch.elapsedMicroseconds);

      final Stopwatch parallelWatch = Stopwatch()..start();
      await codec.encodeWith(runner.call, image);
      parallelWatch.stop();
      parallelTimes.add(parallelWatch.elapsedMicroseconds);
    }
    sequentialTimes.sort();
    parallelTimes.sort();
    final int sequential = sequentialTimes[sequentialTimes.length ~/ 2];
    final int parallel = parallelTimes[parallelTimes.length ~/ 2];
    final String comparison = runner.batchCount == 0 ? 'inline (runner unused)' : '${(sequential / parallel).toStringAsFixed(2)}x';
    stdout.writeln(
      '$label: ${(sequential / 1000).toStringAsFixed(1)} ms -> '
      '${(parallel / 1000).toStringAsFixed(1)} ms ($comparison), '
      '${expected.length} bytes',
    );
  }
}

/// Compares two byte buffers without allocating an intermediate collection.
bool _equalBytes(Uint8List first, Uint8List second) {
  if (first.length != second.length) {
    return false;
  }
  for (int index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}
