import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Records the amount of work offered by each parallel phase.
final class _RecordingRunner {
  /// Number of jobs in every received batch.
  final List<int> batchSizes = <int>[];

  /// Runs a batch inline after recording its size.
  Future<List<R>> call<T, R>(List<T> inputs, R Function(T input) task) async {
    batchSizes.add(inputs.length);
    return <R>[for (final T input in inputs) task(input)];
  }
}

/// Runs at most two isolate jobs concurrently during correctness tests.
Future<List<R>> _runOnTwoIsolates<T, R>(
  List<T> inputs,
  R Function(T input) task,
) => onBoundedIsolates(inputs, task, limit: 2);

/// Builds deterministic, non-trivial RGBA pixels for parallel-path tests.
Image _createSource(int width, int height) {
  final Uint8List pixels = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int offset = (y * width + x) * 4;
      pixels[offset] = (x * 17 + y * 3) & 0xff;
      pixels[offset + 1] = (x * 5 + y * 11) & 0xff;
      pixels[offset + 2] = (x * 7 ^ y * 13) & 0xff;
      pixels[offset + 3] = (x + y) % 19 == 0 ? 96 : 255;
    }
  }
  return Image.fromRgba(
    width: width,
    height: height,
    bytes: pixels,
    copy: false,
  );
}

/// Checks the parallel paths used once images are large enough to benefit.
void main() {
  final Image mediumSource = _createSource(520, 520);
  final Image largeSource = _createSource(1032, 1032);

  final List<(String, RasterCodec, Image)> codecs = <(String, RasterCodec, Image)>[
    ('JPEG 4:4:4', JpegCodec(quality: 91), largeSource),
    ('JPEG 4:2:0', JpegCodec(quality: 91, chroma: JpegChroma.yuv420), largeSource),
    ('PNG', PngCodec(level: 6), mediumSource),
    ('WebP', const WebPCodec(), mediumSource),
  ];

  for (final (String label, RasterCodec codec, Image source) in codecs) {
    test('$label spreads real work and stays byte-identical', () async {
      final Uint8List sequential = codec.encode(source);
      final _RecordingRunner recording = _RecordingRunner();

      final Uint8List inline = await codec.encodeWith(recording.call, source);
      final Uint8List isolated = await codec.encodeWith(
        _runOnTwoIsolates,
        source,
      );

      expect(recording.batchSizes, isNotEmpty);
      expect(recording.batchSizes.every((size) => size > 1), isTrue);
      expect(inline, sequential, reason: 'inline runner');
      expect(isolated, sequential, reason: 'isolate runner');
    });
  }
}
