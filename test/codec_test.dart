import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Exercises the common synchronous codec contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PNG round-trips RGBA pixels synchronously', () {
    final Image source = testImage();

    final Uint8List encoded = encodePng(source);
    final Image decoded = decodePng(encoded);

    expect(ImageFormat.sniff(encoded), ImageFormat.png);
    expectFlutterRgbaClose(decoded, source);
  });

  test('JPEG encodes, decodes, and composites transparency', () {
    final Image source = Image(width: 2, height: 1)
      ..setPixelRgba(0, 0, 255, 0, 0, 255)
      ..setPixelRgba(1, 0, 0, 0, 0, 0);

    final Uint8List encoded = encodeJpg(source, quality: 100);
    final Image decoded = decodeJpg(encoded);

    expect(ImageFormat.sniff(encoded), ImageFormat.jpeg);
    expect(decoded.red(0, 0), greaterThan(200));
    expect(decoded.bytes.sublist(4, 7), everyElement(greaterThan(220)));
  });

  test('JPEG codec configuration is const and reusable', () {
    final JpegCodec codec = JpegCodec(
      quality: 90,
      chroma: JpegChroma.yuv420,
    );
    final Image source = testImage();

    final Uint8List first = codec.encode(source);
    final Uint8List second = codec.encode(source);

    expect(second, first);
  });

  test('format encoders and decoders are const and reusable', () {
    const List<RasterEncoder> encoders = [
      GifEncoder(
        options: IndexedColorOptions(
          ditherAmount: 0,
          transparency: false,
        ),
      ),
      JpegEncoder(
        quality: 90,
        chroma: JpegChroma.yuv420,
      ),
      JpegXlEncoder(),
      PngEncoder(level: 9),
      TgaEncoder(runLengthEncoding: false),
      TiffEncoder(compression: TiffCompression.none),
    ];
    const List<RasterDecoder> decoders = [
      GifDecoder(),
      JpegDecoder(),
      JpegXlDecoder(),
      PngDecoder(),
      TgaDecoder(),
      TiffDecoder(),
    ];
    const List<RasterEncoder> canonicalEncoders = [
      GifEncoder(
        options: IndexedColorOptions(
          ditherAmount: 0,
          transparency: false,
        ),
      ),
      JpegEncoder(
        quality: 90,
        chroma: JpegChroma.yuv420,
      ),
      JpegXlEncoder(),
      PngEncoder(level: 9),
      TgaEncoder(runLengthEncoding: false),
      TiffEncoder(compression: TiffCompression.none),
    ];
    const List<RasterDecoder> canonicalDecoders = [
      GifDecoder(),
      JpegDecoder(),
      JpegXlDecoder(),
      PngDecoder(),
      TgaDecoder(),
      TiffDecoder(),
    ];
    const List<ImageFormat> formats = [
      ImageFormat.gif,
      ImageFormat.jpeg,
      ImageFormat.jpegXl,
      ImageFormat.png,
      ImageFormat.tga,
      ImageFormat.tiff,
    ];
    final Image source = testImage();

    for (int index = 0; index < encoders.length; index++) {
      expect(identical(encoders[index], canonicalEncoders[index]), isTrue);
      expect(identical(decoders[index], canonicalDecoders[index]), isTrue);

      final Uint8List first = encoders[index].convert(source);
      final Uint8List second = encoders[index].convert(source);
      final Image decoded = decoders[index].convert(first);

      expect(second, first);
      expect(ImageFormat.sniff(first), formats[index]);
      expect(decoded.width, source.width);
      expect(decoded.height, source.height);
    }
  });

  test('WebP round-trips RGBA pixels synchronously', () {
    final Image source = testImage();

    final Uint8List encoded = encodeWebP(source);
    final Image decoded = decodeWebP(encoded);

    expect(ImageFormat.sniff(encoded), ImageFormat.webp);
    expectFlutterRgbaClose(decoded, source);
  });

  test('lossless codecs handle varied dimensions and alpha', () {
    final math.Random random = math.Random(314159);
    for (final (int width, int height) in [(1, 1), (1, 7), (7, 1), (31, 33), (33, 35)]) {
      final Uint8List pixels = Uint8List.fromList(List<int>.generate(width * height * 4, (_) => random.nextInt(256)));
      final Image source = Image.fromRgba(width: width, height: height, bytes: pixels);

      final Image png = decodePng(encodePng(source));
      final Image webp = decodeWebP(encodeWebP(source));

      expectFlutterRgbaClose(png, source);
      expectFlutterRgbaClose(webp, source);
    }
  });

  test('every format exposes synchronous Codec converters', () {
    final Image source = testImage();
    final List<Codec<Image, Uint8List>> codecs = [
      const BmpCodec(),
      const GifCodec.customCoders(),
      JpegCodec(
        maxPixels: 1000,
        quality: 90,
        chroma: JpegChroma.yuv420,
      ),
      JpegXlCodec(maxPixels: 1000),
      PngCodec(
        maxPixels: 1000,
        level: 9,
      ),
      const QoiCodec(),
      TgaCodec(
        maxPixels: 1000,
        runLengthEncoding: false,
      ),
      TiffCodec(
        maxPixels: 1000,
        compression: TiffCompression.none,
      ),
      WebPCodec(),
    ];

    for (int index = 0; index < codecs.length; index++) {
      final Codec<Image, Uint8List> codec = codecs[index];
      final RasterCodec rasterCodec = codec as RasterCodec;
      final Uint8List encoded = codec.encoder.convert(source);
      final Image decoded = codec.decoder.convert(encoded);

      expect(rasterCodec.rasterDecoder, isA<RasterDecoder>());
      expect(rasterCodec.rasterEncoder, isA<RasterEncoder>());
      expect(ImageFormat.sniff(encoded), ImageFormat.values[index]);
      expect(decoded.width, source.width);
      expect(decoded.height, source.height);
    }
  });

  test('synchronous codecs run in a worker isolate', () async {
    final Uint8List pixels = Uint8List.fromList(testImage().bytes);

    final List<(ImageFormat?, int, int)> results = await Isolate.run(() {
      final Image image = Image.fromRgba(width: 3, height: 2, bytes: pixels, copy: false);
      final List<Codec<Image, Uint8List>> codecs = [
        const BmpCodec(),
        const GifCodec.customCoders(),
        JpegCodec(),
        JpegXlCodec(),
        PngCodec(),
        const QoiCodec(),
        TgaCodec(),
        TiffCodec(),
        WebPCodec(),
      ];
      final List<(ImageFormat?, int, int)> decodedFormats = [];
      for (final Codec<Image, Uint8List> codec in codecs) {
        final Uint8List encoded = codec.encode(image);
        final Image decoded = codec.decode(encoded);
        decodedFormats.add((ImageFormat.sniff(encoded), decoded.width, decoded.height));
      }
      return decodedFormats;
    });

    expect(results, [for (final ImageFormat format in ImageFormat.values) (format, 3, 2)]);
  });
}

/// Creates a small image containing opaque, translucent, and hidden colors.
Image testImage() => Image.fromRgba(
  width: 3,
  height: 2,
  bytes: Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 12, 34, 56, 78, 250, 240, 230, 220, 128, 64, 32, 16]),
);

/// Verifies RGBA values after Flutter's premultiplied-alpha conversion.
void expectFlutterRgbaClose(Image actual, Image expected) {
  expect(actual.width, expected.width);
  expect(actual.height, expected.height);
  for (int offset = 0; offset < expected.bytes.length; offset += 4) {
    final int alpha = expected.bytes[offset + 3];
    expect(actual.bytes[offset + 3], alpha, reason: 'alpha at pixel ${offset ~/ 4}');
    if (alpha == 0) {
      continue;
    }
    final int tolerance = (255 / alpha).ceil();
    for (int channel = 0; channel < 3; channel++) {
      expect(actual.bytes[offset + channel], closeTo(expected.bytes[offset + channel], tolerance), reason: 'channel $channel at pixel ${offset ~/ 4}');
    }
  }
}
