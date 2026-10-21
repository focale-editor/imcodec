import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Checks external TIFF pixels, opaque Photoshop tags and real ICC payloads.
void main() {
  const String tiffRoot = 'test/fixtures/layered_tiff';
  for (final Map<String, dynamic> entry in _entries(tiffRoot)) {
    test('Independent TIFF ${entry['path']} keeps exact samples and Photoshop data', () {
      final Uint8List bytes = _verified(tiffRoot, entry);
      final DecodedImage decoded = decodeImageData(bytes);
      expect((decoded.width, decoded.height), (6, 4));
      expect(decoded.sampleFormat, entry['depth'] == 16 ? DecodedSampleFormat.uint16 : DecodedSampleFormat.uint8);
      final ByteData samples = ByteData.sublistView(decoded.bytes);
      final int depth = entry['depth'] as int;
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 6; x++) {
          final List<int> expected = [(x * 40 + 1) % 256, (y * 60 + 3) % 256, (x * y * 17 + 1) % 256, 255];
          for (int channel = 0; channel < 4; channel++) {
            final int offset = ((y * 6 + x) * 4 + channel) * depth ~/ 8;
            expect(depth == 8 ? samples.getUint8(offset) : samples.getUint16(offset, Endian.little), expected[channel] * (depth == 8 ? 1 : 257));
          }
        }
      }
      final TiffPhotoshopData photoshop = const TiffDecoder().readPhotoshopData(bytes);
      final Endian order = entry['byteOrder'] == 'little' ? Endian.little : Endian.big;
      expect(photoshop.byteOrder, order);
      expect(sha256.convert(photoshop.imageSourceData!).toString(), entry['imageSourceDataSha256']);
      expect(inspectImage(bytes)!.pixelsPerInch, 300);
      // The public raster encoder emits RGBA8; preserve the opaque layer payload
      // even when the caller deliberately exports an 8-bit composite preview.
      final Image preview = decoded.toImage();
      final Uint8List encoded = encodeTiff(
        preview,
        options: TiffEncodeOptions(byteOrder: order, photoshopData: photoshop),
      );
      expect(decodeTiff(encoded).bytes, preview.bytes);
      expect(const TiffDecoder().readPhotoshopData(encoded).imageSourceData, photoshop.imageSourceData);
    });
  }

  const String iccRoot = 'test/fixtures/artcraft_icc';
  for (final Map<String, dynamic> entry in _entries(iccRoot)) {
    test('Real ICC ${entry['path']} is preserved byte for byte in both TIFF orders', () {
      final Uint8List profile = _verified(iccRoot, entry);
      final Image image = Image.fromRgba(width: 2, height: 1, bytes: Uint8List.fromList([12, 34, 56, 255, 98, 76, 54, 128]));
      for (final Endian order in [Endian.little, Endian.big]) {
        // Opaque transport only: embedding a CMYK/gray profile does not convert
        // the test's RGB samples or make it a colorimetrically matched document.
        final Uint8List bytes = encodeTiff(
          image,
          options: TiffEncodeOptions(byteOrder: order, iccProfile: profile),
        );
        expect(inspectImage(bytes)!.iccProfile, profile);
        expect(decodeImageData(bytes).iccProfile, profile);
        expect(decodeTiff(bytes).bytes, image.bytes);
        expect(() => inspectImage(bytes, maxIccProfileBytes: profile.length - 1), throwsA(isA<ImageCodecException>()));
      }
    });
  }
}

/// Reads fixture metadata without network access during tests.
List<Map<String, dynamic>> _entries(String root) => ((jsonDecode(File('$root/manifest.json').readAsStringSync()) as Map<String, dynamic>)['files'] as List<dynamic>).cast<Map<String, dynamic>>();

/// Checks the identity of independently produced fixture bytes.
Uint8List _verified(String root, Map<String, dynamic> entry) {
  final Uint8List bytes = File('$root/${entry['path']}').readAsBytesSync();
  expect(bytes.length, entry['size']);
  expect(sha256.convert(bytes).toString(), entry['sha256']);
  return bytes;
}
