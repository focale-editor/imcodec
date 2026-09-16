import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks fast PNG encoding and chunk integrity independently of ZCodec's CRC.
void main() {
  test('fast encoding preserves pixels, alpha, and pixel density', () {
    // Arrange.
    const PngEncodeOptions fast = PngEncodeOptions.fast(pixelsPerInch: 144);
    for (final (int width, int height) in [(1, 1), (1, 19), (19, 1), (31, 33)]) {
      final Image source = _source(width, height);

      // Act.
      final Uint8List encoded = encodePng(source, options: fast);
      final Image decoded = decodePng(encoded);
      final DecodedImageMetadata? metadata = inspectImage(encoded);

      // Assert.
      expect(decoded.bytes, source.bytes);
      expect(decoded.width, width);
      expect(decoded.height, height);
      expect(encoded, encodePng(source, options: const PngEncodeOptions(level: 1, pixelsPerInch: 144)));
      expect(metadata?.horizontalPixelsPerInch, closeTo(144, 0.02));
    }
    expect(const PngEncodeOptions().level, 6);
  });

  test('writes reference CRCs and rejects a damaged IDAT checksum', () {
    // Arrange.
    final Image source = _source(31, 33);
    for (final PngEncodeOptions options in const [PngEncodeOptions(), PngEncodeOptions.fast(pixelsPerInch: 144)]) {
      final Uint8List encoded = encodePng(source, options: options);
      final ByteData data = ByteData.sublistView(encoded);
      int imageDataChecksum = -1;

      // Act and assert, including the empty IEND payload and short IHDR.
      for (int offset = 8; offset < encoded.length;) {
        final int length = data.getUint32(offset, Endian.big);
        final int checksumOffset = offset + 8 + length;
        final Uint8List checkedBytes = Uint8List.sublistView(encoded, offset + 4, checksumOffset);
        expect(data.getUint32(checksumOffset, Endian.big), _referenceCrc32(checkedBytes));
        if (data.getUint32(offset + 4, Endian.big) == 0x49444154) {
          imageDataChecksum = checksumOffset;
        }
        offset = checksumOffset + 4;
      }
      expect(imageDataChecksum, greaterThan(0));
      encoded[imageDataChecksum] ^= 1;
      expect(() => decodePng(encoded), throwsA(isA<ImageCodecException>()));
    }
  });
}

/// Builds RGBA rows with transparent, translucent, and opaque samples.
Image _source(int width, int height) {
  final Uint8List pixels = Uint8List(width * height * 4);
  for (int index = 0; index < pixels.length; index++) {
    pixels[index] = (index * 73 + index ~/ 17) & 0xff;
  }
  return Image.fromRgba(width: width, height: height, bytes: pixels, copy: false);
}

/// Computes the PNG CRC bit by bit without sharing its production tables.
int _referenceCrc32(Uint8List bytes) {
  int result = 0xffffffff;
  for (final int byte in bytes) {
    result ^= byte;
    for (int bit = 0; bit < 8; bit++) {
      result = result.isOdd ? 0xedb88320 ^ (result >>> 1) : result >>> 1;
    }
  }
  return (result ^ 0xffffffff) & 0xffffffff;
}
