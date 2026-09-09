import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks the shared `encodeWith` contract across every codec.
///
/// A runner may change how fast encoding runs, never what it produces, and
/// every codec must accept one even when it has nothing to spread.
void main() {
  final math.Random random = math.Random(90210);
  final Uint8List pixels = Uint8List.fromList(List<int>.generate(48 * 31 * 4, (_) => random.nextInt(256)));
  final Image source = Image.fromRgba(width: 48, height: 31, bytes: pixels);

  final Map<ImageFormat, RasterCodec> codecs = <ImageFormat, RasterCodec>{
    ImageFormat.bmp: const BmpCodec(),
    ImageFormat.gif: const GifCodec(),
    ImageFormat.jpeg: const JpegCodec(),
    ImageFormat.jpegXl: const JpegXlCodec(),
    ImageFormat.openExr: const OpenExrCodec(),
    ImageFormat.png: const PngCodec(),
    ImageFormat.qoi: const QoiCodec(),
    ImageFormat.tga: const TgaCodec(),
    ImageFormat.tiff: const TiffCodec(),
    ImageFormat.webp: const WebPCodec(),
  };

  test('every format is covered', () {
    expect(codecs.keys.toSet(), ImageFormatRegistry.formats.toSet());
  });

  for (final MapEntry<ImageFormat, RasterCodec> entry in codecs.entries) {
    if (entry.value is ParallelRasterCodec) {
      test('${entry.key.name} encodes identically with and without a runner', () async {
        final ParallelRasterCodec codec = entry.value as ParallelRasterCodec;
        final Uint8List sequential = codec.encode(source);

        expect(await codec.encodeWith(runSequentially, source), sequential, reason: 'inline runner');
        expect(await codec.encodeWith(onIsolates, source), sequential, reason: 'isolate runner');
        expect(await codec.rasterEncoder.encodeWith(onIsolates, source), sequential, reason: 'encoder entry point');
      });
    }
  }

  test('the format-dispatching helper matches its synchronous twin', () async {
    for (final ImageFormat format in ImageFormatRegistry.formats) {
      final RasterEncodeOptions? options = identical(format, ImageFormat.jpegXl) ? const JpegXlEncodeOptions(effort: JpegXlEffort.fast) : null;
      expect(
        await encodeImageWith(
          onIsolates,
          source,
          format: format,
          options: options,
        ),
        encodeImage(source, format: format, options: options),
        reason: format.name,
      );
    }
  });

  test('the small PNG fallback retains per-operation options', () async {
    const PngEncodeOptions options = PngEncodeOptions(level: 0);
    final Uint8List sequential = encodePng(source, options: options);

    expect(sequential, isNot(encodePng(source)));
    expect(
      await encodePngWith(runSequentially, source, options: options),
      sequential,
    );
  });
}
