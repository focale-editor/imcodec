import 'dart:io';
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl.dart';
import 'package:imcodec/src/codecs/jpeg_xl/encoder/effort.dart';
import 'package:imcodec/src/codecs/png.dart';
import 'package:imcodec/src/codecs/webp.dart';
import 'package:imcodec/src/image.dart';

/// Measures lossless JPEG XL encoding throughput on one image.
void main(List<String> arguments) {
  final String imagePath = arguments.isEmpty ? 'test/fixtures/photos/hubble.jpg' : arguments.first;
  final int iterations = arguments.length < 2 ? 3 : int.parse(arguments[1]);
  final Uint8List encodedSource = File(imagePath).readAsBytesSync();
  final Image image = _decodeSource(imagePath, encodedSource);

  const JpegXlEncoder encoder = JpegXlEncoder(effort: JpegXlEffort.fast);
  final Uint8List warmup = encoder.convert(image);
  final List<double> throughputs = <double>[];
  for (int iteration = 0; iteration < iterations; iteration++) {
    final Stopwatch stopwatch = Stopwatch()..start();
    final Uint8List result = encoder.convert(image);
    stopwatch.stop();
    if (result.length != warmup.length) {
      throw StateError('The encoder produced inconsistent output sizes.');
    }
    final double megapixels = image.width * image.height / 1000000;
    throughputs.add(megapixels * 1000000 / stopwatch.elapsedMicroseconds);
    stdout.writeln(
      'iteration ${iteration + 1}: '
      '${stopwatch.elapsedMilliseconds} ms, '
      '${throughputs.last.toStringAsFixed(2)} MP/s',
    );
  }

  throughputs.sort();
  stdout.writeln(
    '${image.width}x${image.height}, ${warmup.length} bytes, '
    'median ${throughputs[throughputs.length ~/ 2].toStringAsFixed(2)} MP/s',
  );
}

/// Decodes one supported benchmark fixture from its file extension.
Image _decodeSource(String path, Uint8List bytes) {
  final String extension = path.toLowerCase().split('.').last;
  return switch (extension) {
    'jpg' || 'jpeg' => const JpegDecoder().convert(bytes),
    'png' => const PngDecoder().convert(bytes),
    'webp' => const WebPDecoder().convert(bytes),
    _ => throw ArgumentError.value(path, 'path', 'Unsupported benchmark image format'),
  };
}
