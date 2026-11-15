import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// L*, a* and b* of the three pixels of each Lab fixture.
const List<(double, double, double)> _pixels = [(50, -20, 30), (100, 0, 0), (25, 60, -90)];

/// Exercises CIELab and ICCLab TIFF import.
void main() {
  group('Lab TIFF', () {
    for (final (String name, DecodedSampleFormat format, double tolerance) in [
      ('t_cielab8', DecodedSampleFormat.uint8, 0.6 / 255),
      ('t_cielab16', DecodedSampleFormat.uint16, 1e-4),
      ('t_icclab16', DecodedSampleFormat.uint16, 1e-4),
    ]) {
      test('decodes $name to ICC-encoded Lab samples', () {
        // Arrange
        final Uint8List bytes = File('test/fixtures/tiff/$name.tif').readAsBytesSync();

        // Act
        final DecodedImageMetadata metadata = inspectImage(bytes)!;
        final DecodedImage decoded = decodeImageData(bytes);

        // Assert
        expect(metadata.colorModel, DecodedColorModel.lab);
        expect(metadata.requiresExactDecoding, isTrue);
        expect(decoded.colorModel, DecodedColorModel.lab);
        expect(decoded.sampleFormat, format);
        final ByteData data = ByteData.sublistView(decoded.bytes);
        double sample(int pixel, int channel) {
          final int offset = (pixel * 4 + channel) * format.bytesPerChannel;
          return format == DecodedSampleFormat.uint8 ? decoded.bytes[offset] / 255 : data.getUint16(offset, Endian.little) / 65535;
        }

        for (int pixel = 0; pixel < _pixels.length; pixel++) {
          final (double l, double a, double b) = _pixels[pixel];
          expect(sample(pixel, 0), closeTo(l / 100, tolerance));
          expect(sample(pixel, 1), closeTo((a + 128) / 255, tolerance));
          expect(sample(pixel, 2), closeTo((b + 128) / 255, tolerance));
          expect(sample(pixel, 3), 1);
        }
      });
    }

    test('converts Lab to sRGB for the eight-bit view', () {
      // Act: white, and the mid-grey whose L* is 50.
      final Image image = decodeImageData(File('test/fixtures/tiff/t_cielab16.tif').readAsBytesSync()).toImage();

      // Assert
      expect(image.bytes.sublist(4, 8), [255, 255, 255, 255]);
      expect(TiffDecoder().decode(File('test/fixtures/tiff/t_cielab8.tif').readAsBytesSync()).bytes.sublist(4, 7), everyElement(greaterThan(253)));
    });
  });
}
