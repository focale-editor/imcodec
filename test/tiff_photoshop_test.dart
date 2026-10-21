import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Verifies private-tag transport alongside normal TIFF raster decoding.
void main() {
  for (final Endian order in [Endian.big, Endian.little]) {
    for (final TiffCompression compression in TiffCompression.values) {
      test('Preserves Photoshop tags, ICC, density and pixels in $order with $compression', () {
        final Image image = Image.fromRgba(width: 2, height: 1, bytes: Uint8List.fromList([1, 2, 3, 4, 11, 12, 13, 14]));
        final Uint8List layers = Uint8List.fromList('Adobe Photoshop Document Data Block\u0000'.codeUnits);
        final Uint8List resources = Uint8List.fromList([1, 2, 3]);
        final TiffPhotoshopData metadata = TiffPhotoshopData(byteOrder: order, imageSourceData: layers, imageResources: resources);
        final Uint8List icc = Uint8List.fromList(List.generate(19, (i) => i + 1));
        final Uint8List bytes = encodeTiff(
          image,
          options: TiffEncodeOptions(byteOrder: order, compression: compression, photoshopData: metadata, iccProfile: icc, pixelsPerInch: 300),
        );
        final TiffPhotoshopData decoded = const TiffDecoder().readPhotoshopData(bytes);
        expect(decoded.byteOrder, order);
        expect(decoded.imageSourceData, layers);
        expect(decoded.imageResources, resources);
        expect(decodeTiff(bytes).bytes, image.bytes);
        final DecodedImageMetadata raster = inspectImage(bytes)!;
        expect(raster.iccProfile, icc);
        expect(raster.pixelsPerInch, 300);
        expect(() => decoded.imageSourceData![0] = 0, throwsUnsupportedError);
      });
    }
  }

  test('Rejects a mismatched layer byte order before producing a file', () {
    final Image image = Image.fromRgba(width: 1, height: 1, bytes: Uint8List(4));
    expect(
      () => encodeTiff(
        image,
        options: TiffEncodeOptions(
          photoshopData: TiffPhotoshopData(byteOrder: Endian.big, imageSourceData: Uint8List(5)),
        ),
      ),
      throwsA(isA<ImageCodecException>()),
    );
  });

  test('Absent private tags are distinct from an empty opaque payload', () {
    final Image image = Image.fromRgba(width: 1, height: 1, bytes: Uint8List(4));
    expect(const TiffDecoder().readPhotoshopData(encodeTiff(image)).isNotEmpty, isFalse);
    final Uint8List bytes = encodeTiff(
      image,
      options: TiffEncodeOptions(
        photoshopData: TiffPhotoshopData(byteOrder: Endian.little, imageResources: Uint8List(0)),
      ),
    );
    expect(const TiffDecoder().readPhotoshopData(bytes).imageResources, isEmpty);
    expect(() => const TiffDecoder().readPhotoshopData(Uint8List(6)), throwsA(isA<ImageCodecException>()));
  });
}
