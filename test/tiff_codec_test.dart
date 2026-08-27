import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Exercises baseline TIFF import and export.
void main() {
  group('TIFF', () {
    test('round-trips uncompressed and PackBits RGBA exactly', () {
      final Image source = _testImage();

      final Uint8List uncompressed = encodeTiff(source, compression: TiffCompression.none);
      final Uint8List packBits = encodeTiff(source);

      expect(ImageFormat.sniff(uncompressed), ImageFormat.tiff);
      expect(ImageFormat.sniff(packBits), ImageFormat.tiff);
      expect((decodeTiff(uncompressed)).bytes, source.bytes);
      expect((decodeTiff(packBits)).bytes, source.bytes);
    });

    test('decodes an independently encoded LZW RGBA fixture', () {
      final Image decoded = decodeTiff(base64Decode(_lzwFixture));

      expect(decoded.width, 3);
      expect(decoded.height, 2);
      expect(decoded.bytes, _testImage().bytes);
    });

    test('applies orientation while decoding', () {
      final Uint8List encoded = encodeTiff(_testImage(), compression: TiffCompression.none);
      final ByteData data = ByteData.sublistView(encoded);
      const int orientationEntryValue = 8 + 2 + 6 * 12 + 8;
      data.setUint16(orientationEntryValue, 6, Endian.little);

      final Image decoded = decodeTiff(encoded);

      expect(decoded.width, 2);
      expect(decoded.height, 3);
      expect(decoded.bytes, [12, 34, 56, 78, 255, 0, 0, 255, 250, 240, 230, 220, 0, 255, 0, 128, 128, 64, 32, 16, 0, 0, 255, 0]);
    });

    test('automatic dispatch decodes TIFF', () {
      final Image source = _testImage();

      final Image decoded = decodeImage(encodeTiff(source));

      expect(decoded.bytes, source.bytes);
    });

    test('enforces pixel limits and rejects truncation', () {
      final Uint8List encoded = encodeTiff(_testImage());

      expect(() => decodeTiff(encoded, maxPixels: 1), throwsA(isA<ImageCodecException>()));
      expect(() => decodeTiff(Uint8List.sublistView(encoded, 0, 20)), throwsA(isA<ImageCodecException>()));
    });
  });
}

/// Creates pixels that exercise opacity, transparency, and PackBits literals.
Image _testImage() => Image.fromRgba(
  width: 3,
  height: 2,
  bytes: Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 12, 34, 56, 78, 250, 240, 230, 220, 128, 64, 32, 16]),
);

/// TIFF generated independently by Pillow using LZW compression.
const String _lzwFixture =
    'SUkqACIAAACAP8AACBQJAQOBAwRDgnPp4OZuIAgCAIQEAAsAAAEDAAEAAAADAAAAAQEDAAEAAAACAAAAAgEDAAQAAACsAAAAAwEDAAEAAAAFAAAABgEDAAEAAAACAAAAEQEEAAEAAAAIAAAAFQEDAAEAAAAEAAAAFgEDAAEAAAACAAAAFwEEAAEAAAAZAAAAHAEDAAEAAAABAAAAUgEDAAEAAAACAAAAAAAAAAgACAAIAAgA';
