import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Pins the behavior of defects that were fixed in the codecs.
void main() {
  test('TIFF PackBits never emits an over-long literal packet', () {
    // A literal run of exactly 127 bytes followed by a two-byte repeat used to
    // produce a 129-byte packet, whose 128 header byte is the PackBits no-op.
    final Uint8List pixels = Uint8List(33 * 4);
    for (int index = 0; index < 127; index++) {
      pixels[index] = index;
    }
    pixels[127] = 200;
    pixels[128] = 200;
    for (int index = 129; index < pixels.length; index++) {
      pixels[index] = index * 37 % 251;
    }
    final Image source = Image.fromRgba(width: 33, height: 1, bytes: pixels);

    final Uint8List encoded = encodeTiff(source);

    expect(decodeTiff(encoded).bytes, source.bytes);
  });

  test('TIFF PackBits packets stay inside one row', () {
    // A run spanning a row boundary is legal for this decoder but not for the
    // format, so the encoder must restart at every row.
    final Image source = Image.fromRgba(width: 4, height: 8, bytes: Uint8List(4 * 8 * 4));

    final Uint8List encoded = encodeTiff(source);
    final int stripByteCount = ByteData.sublistView(encoded).getUint32(8 + 2 + 9 * 12 + 8, Endian.little);

    // Sixteen zero bytes per row cannot be merged across rows, so each of the
    // eight rows contributes its own two-byte repeat packet.
    expect(stripByteCount, 8 * 2);
    expect(decodeTiff(encoded).bytes, source.bytes);
  });

  test('JPEG output ends without a padding byte when already aligned', () {
    // Padding a byte-aligned entropy stream used to append a stuffed 0xff 0x00
    // pair before the end-of-image marker.
    for (int size = 8; size <= 40; size += 8) {
      final Image source = Image(width: size, height: size);
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          source.setPixelRgb(x, y, x * 6 % 256, y * 7 % 256, (x + y) * 5 % 256);
        }
      }

      final Uint8List encoded = encodeJpg(source, quality: 80);

      expect(encoded[encoded.length - 2], 0xff);
      expect(encoded[encoded.length - 1], 0xd9);
      final bool endsWithStuffedPadding = encoded[encoded.length - 4] == 0xff && encoded[encoded.length - 3] == 0x00;
      expect(endsWithStuffedPadding, isFalse, reason: 'size $size ends with a redundant stuffed padding byte');
    }
  });

  test('QOI difference opcodes wrap around like the reference encoder', () {
    final Image source = Image(width: 2, height: 1)
      ..setPixelRgba(0, 0, 0, 0, 0, 255)
      ..setPixelRgba(1, 0, 255, 0, 0, 255);

    final Uint8List encoded = encodeQoi(source);

    // Both pixels fit in one-byte opcodes: an index hit and a difference.
    expect(encoded.length, 14 + 2 + 8);
    expect(decodeQoi(encoded).bytes, source.bytes);
  });

  test('WebP marks opaque images as carrying no alpha', () {
    final Image opaque = Image(width: 4, height: 4);
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        opaque.setPixelRgb(x, y, x * 60, y * 60, 128);
      }
    }

    final Uint8List encoded = encodeWebP(opaque);
    const int vp8lHeaderOffset = 20 + 1;
    final int header = encoded[vp8lHeaderOffset] | (encoded[vp8lHeaderOffset + 1] << 8) | (encoded[vp8lHeaderOffset + 2] << 16) | (encoded[vp8lHeaderOffset + 3] << 24);

    expect((header >> 28) & 1, 0);
    expect(decodeWebP(encoded).bytes, opaque.bytes);
  });

  test('WebP lossless predictor accounts for alpha residuals', () {
    // With constant RGB, ignoring alpha always selected the left predictor.
    // Vertical prediction is substantially cheaper for this repeated alpha
    // row, reducing the deterministic stream from 64 bytes to 58 bytes.
    final Image source = Image(width: 128, height: 128);
    for (int y = 0; y < source.height; ++y) {
      for (int x = 0; x < source.width; ++x) {
        source.setPixelRgba(x, y, 100, 100, 100, x.isEven ? 0 : 255);
      }
    }

    final Uint8List encoded = encodeWebP(source);

    expect(encoded.length, lessThanOrEqualTo(60));
    expect(decodeWebP(encoded).bytes, source.bytes);
  });

  test('PNG accepts trailing bytes after its end chunk', () {
    final Image source = Image(width: 3, height: 2)..setPixelRgba(1, 1, 10, 20, 30, 40);
    final Uint8List encoded = encodePng(source);
    final Uint8List padded = Uint8List(encoded.length + 4)..setRange(0, encoded.length, encoded);

    expect(decodePng(padded).bytes, source.bytes);
  });

  test('TGA reads a thirty-two-bit image whose attribute bytes are all zero', () {
    final Uint8List header = Uint8List.fromList([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 32, 0]);
    final Uint8List pixels = Uint8List.fromList([10, 20, 30, 0, 40, 50, 60, 0]);
    final Uint8List encoded = Uint8List(header.length + pixels.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + pixels.length, pixels);

    final Image decoded = decodeTga(encoded);

    expect(decoded.bytes, [30, 20, 10, 255, 60, 50, 40, 255]);
  });

  test('every lossless codec round-trips run and packet boundaries', () {
    final math.Random random = math.Random(31337);
    for (final (int width, int height) in [(1, 1), (128, 1), (129, 1), (1, 129), (63, 65)]) {
      final Uint8List pixels = Uint8List(width * height * 4);
      for (int index = 0; index < pixels.length; index += 4) {
        // Mix long runs with noise so both packet kinds appear in every codec.
        final bool run = random.nextInt(3) == 0;
        final int value = run ? 128 : random.nextInt(256);
        pixels[index] = value;
        pixels[index + 1] = run ? 128 : random.nextInt(256);
        pixels[index + 2] = run ? 128 : random.nextInt(256);
        pixels[index + 3] = run ? 255 : random.nextInt(256);
      }
      final Image source = Image.fromRgba(width: width, height: height, bytes: pixels);
      final String label = '$width x $height';

      expect(decodeBmp(encodeBmp(source)).bytes, source.bytes, reason: 'BMP $label');
      expect(decodeTga(encodeTga(source)).bytes, source.bytes, reason: 'TGA RLE $label');
      expect(decodeTga(encodeTga(source, runLengthEncoding: false)).bytes, source.bytes, reason: 'TGA raw $label');
      expect(decodeQoi(encodeQoi(source)).bytes, source.bytes, reason: 'QOI $label');
      expect(decodePng(encodePng(source)).bytes, source.bytes, reason: 'PNG $label');
      expect(decodeTiff(encodeTiff(source)).bytes, source.bytes, reason: 'TIFF PackBits $label');
      expect(decodeTiff(encodeTiff(source, compression: TiffCompression.none)).bytes, source.bytes, reason: 'TIFF raw $label');
      expect(decodeWebP(encodeWebP(source)).bytes, source.bytes, reason: 'WebP $label');
    }
  });
}
