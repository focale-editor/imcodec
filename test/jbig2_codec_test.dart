import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Exercises JBIG2 integration, binary encoding, PDF streams and malformed data.
void main() {
  group('JBIG2', () {
    final List<dynamic> fixtures = jsonDecode(File('test/fixtures/jbig2/manifest.json').readAsStringSync()) as List<dynamic>;
    for (final dynamic entry in fixtures) {
      final Map<String, dynamic> fixture = entry as Map<String, dynamic>;
      test('independent jbig2dec pixels for ${fixture['file']}', () {
        final Uint8List bytes = File('test/fixtures/jbig2/${fixture['file']}').readAsBytesSync();
        expect(sha256.convert(bytes).toString(), fixture['sha256']);
        final String? globalsName = fixture['globals'] as String?;
        final Uint8List? globals = globalsName == null ? null : File('test/fixtures/jbig2/$globalsName').readAsBytesSync();
        if (globals != null) {
          expect(sha256.convert(globals).toString(), fixture['globalsSha256']);
        }
        final List<dynamic> pages = fixture['pages'] as List<dynamic>;
        expect(pages, isNotEmpty);
        for (int index = 0; index < pages.length; index++) {
          final Map<String, dynamic> page = pages[index] as Map<String, dynamic>;
          final Jbig2DecodeOptions options = Jbig2DecodeOptions(page: index + 1);
          final Image image = ImageFormat.jbig2.matches(bytes) ? decodeJbig2(bytes, options: options) : const Jbig2Decoder().decodeEmbedded(bytes, globals: globals, decodeOptions: options);
          expect(image.width, page['width']);
          expect(image.height, page['height']);
          expect(sha256.convert(image.bytes).toString(), page['rgbaSha256']);
        }
      });
    }
    for (final (int, int) size in [(1, 1), (7, 3), (8, 9), (17, 15), (129, 63)]) {
      for (final bool prediction in [false, true]) {
        test('round-trips ${size.$1}x${size.$2}, prediction $prediction', () {
          final Image source = _binaryImage(width: size.$1, height: size.$2);
          final Uint8List encoded = encodeJbig2(source, options: Jbig2EncodeOptions(typicalPrediction: prediction));
          final Image decoded = decodeImage(encoded);
          expect(ImageFormat.sniff(encoded), ImageFormat.jbig2);
          expect(decoded.width, source.width);
          expect(decoded.height, source.height);
          expect(decoded.bytes, source.bytes);
          expect(const Jbig2Codec().decoder.convert(encoded).bytes, source.bytes);
        });
      }
    }
    test('rejects a mislabeled Flash file from the external corpus', () {
      final Uint8List bytes = File('test/fixtures/jbig2/001.jb2').readAsBytesSync();
      expect(ImageFormat.jbig2.matches(bytes), isFalse);
      expect(() => decodeJbig2(bytes), throwsA(isA<ImageCodecException>()));
    });
    test('supports PDF segment streams explicitly', () {
      final Image source = _binaryImage(width: 29, height: 19);
      final Uint8List encoded = const Jbig2Encoder().encodeEmbedded(source);
      expect(ImageFormat.jbig2.matches(encoded), isFalse);
      expect(const Jbig2Decoder().decodeEmbedded(encoded).bytes, source.bytes);
      expect(() => decodeJbig2(encoded), throwsA(isA<ImageCodecException>()));
    });
    test('rejects color unless binarization was explicitly requested', () {
      final Image source = Image.fromRgba(width: 4, height: 1, bytes: Uint8List.fromList([0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 255, 0, 0, 0, 0]));
      expect(() => encodeJbig2(source), throwsA(isA<ImageCodecException>()));
      final Image decoded = decodeJbig2(encodeJbig2(source, options: const Jbig2EncodeOptions(threshold: 128)));
      expect(decoded.bytes, [0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255]);
    });
    test('enforces page, segment and intermediate bitmap limits', () {
      final Uint8List encoded = encodeJbig2(_binaryImage(width: 17, height: 15));
      for (final Jbig2DecodeOptions options in [
        const Jbig2DecodeOptions(maxPixels: 254),
        const Jbig2DecodeOptions(maxSegments: 1),
        const Jbig2DecodeOptions(maxWorkingBytes: 1),
        const Jbig2DecodeOptions(page: 2),
      ]) {
        expect(() => decodeJbig2(encoded, options: options), throwsA(isA<ImageCodecException>()));
      }
      expect(() => decodeJbig2(encoded, options: const Jbig2DecodeOptions(maxPixels: 0)), throwsRangeError);
    });
    test('rejects every truncation within the image payload', () {
      final Uint8List encoded = encodeJbig2(_binaryImage(width: 17, height: 15));
      for (int length = 0; length < encoded.length - 22; length++) {
        expect(() => decodeJbig2(Uint8List.sublistView(encoded, 0, length)), throwsA(isA<ImageCodecException>()), reason: 'length $length');
      }
    });
    test('inspects dimensions and rejects native sample budgets before decode', () {
      final Uint8List bytes = encodeJbig2(_binaryImage(width: 17, height: 15));
      final DecodedImageMetadata info = inspectImage(bytes)!;
      expect((info.width, info.height), (17, 15));
      expect(decodeImageData(bytes).toImage().bytes, decodeJbig2(bytes).bytes);
      expect(() => decodeImageData(bytes, maxDecodedBytes: 1019), throwsA(isA<ImageCodecException>()));
    });
    test('decodes random-access organization and selects the second page', () {
      final Image first = _binaryImage(width: 17, height: 15);
      final Image second = _binaryImage(width: 9, height: 7);
      final List<(Uint8List, Uint8List)> segments = _segments(encodeJbig2(first));
      final Uint8List random = _file(segments: segments, randomAccess: true);
      expect(decodeJbig2(random).bytes, first.bytes);
      final List<(Uint8List, Uint8List)> pages = [...segments.take(3)];
      final List<(Uint8List, Uint8List)> next = _segments(encodeJbig2(second));
      for (int index = 0; index < next.length; index++) {
        final Uint8List header = Uint8List.fromList(next[index].$1);
        ByteData.sublistView(header).setUint32(0, index + 4);
        if (header[4] != 51) {
          header[6] = 2;
        }
        pages.add((header, next[index].$2));
      }
      final Uint8List multi = _file(segments: pages, pages: 2);
      expect(decodeJbig2(multi).bytes, first.bytes);
      expect(decodeImage(multi, options: const Jbig2DecodeOptions(page: 2)).bytes, second.bytes);
    });
    test('respects region offsets even when region dimensions match the page', () {
      final Image source = _binaryImage(width: 17, height: 15);
      final List<(Uint8List, Uint8List)> segments = _segments(encodeJbig2(source));
      ByteData.sublistView(segments[1].$2).setUint32(8, 1);
      final Image decoded = decodeJbig2(_file(segments: segments));
      for (int y = 0; y < source.height; y++) {
        expect(decoded.bytes[(y * source.width) * 4], 255);
        for (int x = 1; x < source.width; x++) {
          expect(decoded.bytes[(y * source.width + x) * 4], source.bytes[(y * source.width + x - 1) * 4]);
        }
      }
    });
    test('rejects duplicate, missing and forward segment references', () {
      final List<(Uint8List, Uint8List)> segments = _segments(encodeJbig2(_binaryImage(width: 8, height: 8)));
      final Uint8List duplicate = Uint8List.fromList(segments[1].$1);
      ByteData.sublistView(duplicate).setUint32(0, 1);
      expect(() => decodeJbig2(_file(segments: [segments[0], (duplicate, segments[1].$2), ...segments.skip(2)])), throwsA(isA<ImageCodecException>()));
      for (final int number in [0, 2]) {
        final Uint8List reference = Uint8List.fromList([...segments[1].$1.take(5), 32, number, ...segments[1].$1.skip(6)]);
        expect(() => decodeJbig2(_file(segments: [segments[0], (reference, segments[1].$2), ...segments.skip(2)])), throwsA(isA<ImageCodecException>()));
      }
    });
    test('decodes unknown-height striped pages and unknown-length regions', () {
      final Image source = _binaryImage(width: 17, height: 15);
      final List<(Uint8List, Uint8List)> segments = _segments(encodeJbig2(source));
      ByteData.sublistView(segments[0].$2)
        ..setUint32(4, 0xffffffff)
        ..setUint16(17, 0x8000);
      final Uint8List stripe = (ByteData(4)..setUint32(0, source.height - 1)).buffer.asUint8List();
      final List<(Uint8List, Uint8List)> striped = [
        segments[0],
        segments[1],
        _testSegment(number: 3, type: 50, data: stripe),
        _testSegment(number: 4, type: 49),
        _testSegment(number: 5, type: 51, page: 0),
      ];
      expect(inspectImage(_file(segments: striped))!.height, source.height);
      expect(decodeJbig2(_file(segments: striped)).bytes, source.bytes);
      final Uint8List header = Uint8List.fromList(segments[1].$1);
      ByteData.sublistView(header).setUint32(7, 0xffffffff);
      final Uint8List rows = (ByteData(4)..setUint32(0, source.height)).buffer.asUint8List();
      striped[1] = (header, Uint8List.fromList([...segments[1].$2, ...rows]));
      expect(decodeJbig2(_file(segments: striped)).bytes, source.bytes);
    });
    test('rejects required extensions and oversized symbol dictionaries', () {
      final List<(Uint8List, Uint8List)> segments = _segments(encodeJbig2(_binaryImage(width: 8, height: 8)));
      final (Uint8List, Uint8List) extension = _testSegment(number: 5, type: 62, data: Uint8List.fromList([128, 0, 0, 1]));
      expect(() => decodeJbig2(_file(segments: [segments[0], extension, ...segments.skip(1)])), throwsA(isA<ImageCodecException>()));
      final Uint8List dictionary = Uint8List.fromList([0, 0, 3, 255, 253, 255, 2, 254, 254, 254, 0, 0, 0, 1, 255, 255, 255, 255]);
      final Uint8List text = Uint8List(23);
      ByteData.sublistView(text)
        ..setUint32(0, 8)
        ..setUint32(4, 8)
        ..setUint32(19, 1);
      final List<(Uint8List, Uint8List)> oversized = [
        segments[0],
        _testSegment(number: 2, type: 0, data: dictionary),
        _testSegment(number: 3, type: 7, data: text, reference: 2),
        _testSegment(number: 4, type: 49),
        _testSegment(number: 5, type: 51, page: 0),
      ];
      expect(() => decodeJbig2(_file(segments: oversized)), throwsA(isA<ImageCodecException>()));
    });
    test('writes a reproducible fixture for an independent decoder', () {
      final Image source = _binaryImage(width: 129, height: 63);
      final Directory directory = Directory('build/jbig2_validation')..createSync(recursive: true);
      File('${directory.path}/encoded.jb2').writeAsBytesSync(encodeJbig2(source));
      File('${directory.path}/expected.rgba').writeAsBytesSync(source.bytes);
    });
  });
}

/// Creates deterministic binary pixels with solid, repeated and noisy rows.
Image _binaryImage({required int width, required int height}) {
  final math.Random random = math.Random(7301);
  final Uint8List pixels = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int value = y < 2 ? 255 : (y < 4 ? 0 : (random.nextBool() ? 255 : 0));
      final int offset = (y * width + x) * 4;
      pixels.setRange(offset, offset + 4, [value, value, value, 255]);
    }
  }
  return Image.fromRgba(width: width, height: height, bytes: pixels);
}

/// Splits the simple sequential files emitted by this test's encoder.
List<(Uint8List, Uint8List)> _segments(Uint8List bytes) {
  final List<(Uint8List, Uint8List)> segments = [];
  int offset = 13;
  while (offset < bytes.length) {
    final int length = ByteData.sublistView(bytes).getUint32(offset + 7);
    segments.add((Uint8List.fromList(bytes.sublist(offset, offset + 11)), Uint8List.fromList(bytes.sublist(offset + 11, offset + 11 + length))));
    offset += 11 + length;
  }
  return segments;
}

/// Builds sequential or random-access standalone containers from test segments.
Uint8List _file({required List<(Uint8List, Uint8List)> segments, bool randomAccess = false, int pages = 1}) {
  final BytesBuilder bytes = BytesBuilder()..add([151, 74, 66, 50, 13, 10, 26, 10, if (randomAccess) 0 else 1, 0, 0, 0, pages]);
  for (final (Uint8List, Uint8List) segment in segments) {
    bytes.add(segment.$1);
    if (!randomAccess) {
      bytes.add(segment.$2);
    }
  }
  if (randomAccess) {
    for (final (Uint8List, Uint8List) segment in segments) {
      bytes.add(segment.$2);
    }
  }
  return bytes.takeBytes();
}

/// Creates a short test segment with at most one one-byte reference.
(Uint8List, Uint8List) _testSegment({required int number, required int type, int page = 1, Uint8List? data, int? reference}) {
  final Uint8List payload = data ?? Uint8List(0);
  final BytesBuilder header = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, number)).buffer.asUint8List())
    ..add([type, if (reference == null) 0 else 32, ?reference, page])
    ..add((ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List());
  return (header.takeBytes(), payload);
}
