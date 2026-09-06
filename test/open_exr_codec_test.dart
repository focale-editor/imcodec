import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

void main() {
  test('decodes an OpenEXR 3.2 reference-library file', () {
    // Arrange.
    final Uint8List encoded = base64Decode(
      'di8xAQIAAABjaGFubmVscwBjaGxpc3QASQAAAEEAAQAAAAAAAAABAAAAAQAAAEIA'
      'AQAAAAAAAAABAAAAAQAAAEcAAQAAAAAAAAABAAAAAQAAAFIAAQAAAAAAAAABAAAA'
      'AQAAAABjb21wcmVzc2lvbgBjb21wcmVzc2lvbgABAAAAAGRhdGFXaW5kb3cAYm94'
      'MmkAEAAAAAAAAAAAAAAAAQAAAAEAAABkaXNwbGF5V2luZG93AGJveDJpABAAAAAA'
      'AAAAAAAAAAEAAAABAAAAbGluZU9yZGVyAGxpbmVPcmRlcgABAAAAAHBpeGVsQXNw'
      'ZWN0UmF0aW8AZmxvYXQABAAAAAAAgD9zY3JlZW5XaW5kb3dDZW50ZXIAdjJmAAgA'
      'AAAAAAAAAAAAAHNjcmVlbldpbmRvd1dpZHRoAGZsb2F0AAQAAAAAAIA/AFsBAAAA'
      'AAAAcwEAAAAAAAAAAAAAEAAAAAA4ADgAAAAAAAAAAAA8ADwBAAAAEAAAAAA4ADgA'
      'AAAAAAAAAAA8ADw=',
    );

    // Act.
    final DecodedImage decoded = decodeOpenExrData(encoded);
    final Float32List pixels = Float32List.sublistView(decoded.bytes);

    // Assert.
    expect(decoded.width, 2);
    expect(decoded.height, 2);
    expect(pixels[0], closeTo(1, 0.001));
    expect(pixels[1], closeTo(0, 0.001));
    expect(pixels[2], closeTo(0, 0.001));
    expect(pixels[3], closeTo(0.5, 0.001));
  });

  for (final OpenExrCompression compression in OpenExrCompression.values) {
    test('round-trips half-float RGBA with ${compression.name}', () {
      // Arrange.
      final Uint8List pixels = Uint8List(7 * 19 * 4);
      for (int pixel = 0; pixel < 7 * 19; pixel++) {
        final int offset = pixel * 4;
        pixels[offset] = (pixel * 29) & 0xff;
        pixels[offset + 1] = (pixel * 71 + 13) & 0xff;
        pixels[offset + 2] = (pixel * 11 + 199) & 0xff;
        pixels[offset + 3] = (pixel * 47 + 31) & 0xff;
      }
      final Image source = Image.fromRgba(
        width: 7,
        height: 19,
        bytes: pixels,
      );

      // Act.
      final Uint8List encoded = OpenExrCodec(
        compression: compression,
      ).encode(source);
      final DecodedImage decoded = decodeOpenExrData(encoded);
      final Image display = decoded.toImage();

      // Assert.
      expect(ImageFormat.sniff(encoded), ImageFormat.openExr);
      expect(inspectImage(encoded)?.bitsPerChannel, 32);
      expect(decoded.sampleFormat, DecodedSampleFormat.float32);
      expect(display.width, source.width);
      expect(display.height, source.height);
      for (int index = 0; index < pixels.lengthInBytes; index++) {
        expect(display.bytes[index], closeTo(pixels[index], 1));
      }
    });
  }

  test('rejects tiled OpenEXR instead of interpreting tile offsets as rows', () {
    // Arrange.
    final Image source = Image(width: 1, height: 1);
    final Uint8List encoded = encodeOpenExr(source);
    encoded[5] |= 0x02;

    // Act and assert.
    expect(
      () => decodeOpenExrData(encoded),
      throwsA(isA<ImageCodecException>()),
    );
  });

  test('rejects unsupported decreasing scan-line order explicitly', () {
    // Arrange.
    final Uint8List encoded = encodeOpenExr(Image(width: 1, height: 1));
    final int attribute = _findBytes(
      encoded,
      ascii.encode('lineOrder\u0000lineOrder\u0000'),
    );
    encoded[attribute + 24] = 1;

    // Act and assert.
    expect(
      () => decodeOpenExrData(encoded),
      throwsA(isA<ImageCodecException>()),
    );
  });

  test('preserves extended highlights from float input', () {
    // Arrange.
    final Float32List pixels = Float32List.fromList([
      2.0,
      1.25,
      0.5,
      1.0,
      -0.5,
      -0.25,
      -0.1,
      1.0,
    ]);

    // Act.
    final Uint8List encoded = encodeOpenExrFloat32Rgba(
      width: 2,
      height: 1,
      pixels: pixels,
    );
    final DecodedImage decodedImage = decodeOpenExrData(encoded);
    final Float32List decoded = Float32List.sublistView(decodedImage.bytes);

    // Assert.
    expect(decoded[0], closeTo(2.0, 0.003));
    expect(decoded[1], closeTo(1.25, 0.003));
    expect(decoded[2], closeTo(0.5, 0.003));
    expect(decoded[3], 1.0);
    expect(decoded[4], closeTo(-0.5, 0.003));
    expect(decoded[5], closeTo(-0.25, 0.003));
    expect(decoded[6], closeTo(-0.1, 0.003));
    expect(decoded[7], 1.0);
  });

  test('enforces the native floating-point output byte limit', () {
    // Arrange.
    final Uint8List encoded = encodeOpenExr(Image(width: 2, height: 2));

    // Act and assert.
    expect(
      () => decodeOpenExrData(encoded, maxDecodedBytes: 63),
      throwsA(isA<ImageCodecException>()),
    );
  });

  test('bounds expanded blocks containing arbitrary extra channels', () {
    // Arrange.
    final Uint8List encoded = _addHalfChannels(
      encodeOpenExr(
        Image(width: 1, height: 1),
        compression: OpenExrCompression.none,
      ),
      5,
    );

    // Act and assert.
    expect(
      () => decodeOpenExrData(encoded, maxDecodedBytes: 16),
      throwsA(isA<ImageCodecException>()),
    );
  });
}

/// Finds [needle] in [haystack] and fails the fixture if it is absent.
int _findBytes(Uint8List haystack, List<int> needle) {
  for (int start = 0; start <= haystack.lengthInBytes - needle.length; start++) {
    bool matches = true;
    for (int index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return start;
    }
  }
  throw StateError('OpenEXR fixture does not contain the requested bytes');
}

/// Adds unreferenced half-float channels to a single-block fixture header.
Uint8List _addHalfChannels(Uint8List encoded, int count) {
  final List<int> signature = ascii.encode('channels\u0000chlist\u0000');
  final int attributeOffset = _findBytes(encoded, signature);
  final int lengthOffset = attributeOffset + signature.length;
  final ByteData sourceData = ByteData.sublistView(encoded);
  final int payloadLength = sourceData.getUint32(lengthOffset, Endian.little);
  final int payloadStart = lengthOffset + Uint32List.bytesPerElement;
  final int payloadEnd = payloadStart + payloadLength;
  final BytesBuilder additions = BytesBuilder(copy: false);
  for (int index = 0; index < count; index++) {
    final ByteData descriptor = ByteData(16)
      ..setInt32(0, 1, Endian.little)
      ..setInt32(8, 1, Endian.little)
      ..setInt32(12, 1, Endian.little);
    additions
      ..add(ascii.encode('extra$index\u0000'))
      ..add(descriptor.buffer.asUint8List());
  }
  final Uint8List addedBytes = additions.takeBytes();
  final Uint8List result = Uint8List(encoded.lengthInBytes + addedBytes.lengthInBytes)
    ..setRange(0, payloadEnd - 1, encoded)
    ..setRange(payloadEnd - 1, payloadEnd - 1 + addedBytes.lengthInBytes, addedBytes)
    ..setRange(payloadEnd - 1 + addedBytes.lengthInBytes, encoded.lengthInBytes + addedBytes.lengthInBytes, encoded, payloadEnd - 1);
  final ByteData resultData = ByteData.sublistView(result)
    ..setUint32(
      lengthOffset,
      payloadLength + addedBytes.lengthInBytes,
      Endian.little,
    );
  final int offsetTable = _openExrHeaderEnd(result);
  resultData.setUint64(
    offsetTable,
    resultData.getUint64(offsetTable, Endian.little) + addedBytes.lengthInBytes,
    Endian.little,
  );
  return result;
}

/// Locates the first scan-line offset after a bounded test header.
int _openExrHeaderEnd(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  int offset = 8;
  while (bytes[offset] != 0) {
    while (bytes[offset++] != 0) {}
    while (bytes[offset++] != 0) {}
    final int length = data.getUint32(offset, Endian.little);
    offset += Uint32List.bytesPerElement + length;
  }
  return offset + 1;
}
