import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';
import 'package:zcodec/zcodec.dart';

void main() {
  group('native decoded images', () {
    test('retain exact RGBA16 PNG samples and an embedded ICC payload', () {
      final Uint8List profile = Uint8List.fromList(<int>[
        0x01,
        0x23,
        0x45,
        0x67,
        0x89,
        0xab,
        0xcd,
        0xef,
      ]);
      final Uint8List encoded = _buildRgba16Png(
        red: 32769,
        green: 16386,
        blue: 49155,
        alpha: 32767,
        iccProfile: profile,
      );

      final DecodedImageMetadata? metadata = inspectImage(encoded);
      expect(metadata, isNotNull);
      expect(metadata!.width, 1);
      expect(metadata.height, 1);
      expect(metadata.bitsPerChannel, 16);
      expect(metadata.colorModel, DecodedColorModel.rgb);
      expect(metadata.iccProfile, orderedEquals(profile));
      expect(metadata.requiresExactDecoding, isTrue);

      final DecodedImage decoded = decodeImageData(encoded);
      final ByteData samples = ByteData.sublistView(decoded.bytes);
      expect(decoded.sampleFormat, DecodedSampleFormat.uint16);
      expect(decoded.colorModel, DecodedColorModel.rgb);
      expect(decoded.iccProfile, orderedEquals(profile));
      expect(samples.getUint16(0, Endian.little), 32769);
      expect(samples.getUint16(2, Endian.little), 16386);
      expect(samples.getUint16(4, Endian.little), 49155);
      expect(samples.getUint16(6, Endian.little), 32767);
      expect(decoded.toImage().bytes, orderedEquals(<int>[128, 64, 191, 127]));
    });

    test('retain float32 CMYK TIFF process channels', () {
      final Uint8List encoded = _buildCmykFloatTiff(
        cyan: 0.125,
        magenta: 0.25,
        yellow: 0.5,
        black: 0.75,
      );

      final DecodedImageMetadata? metadata = inspectImage(encoded);
      expect(metadata, isNotNull);
      expect(metadata!.bitsPerChannel, 32);
      expect(metadata.colorModel, DecodedColorModel.cmyk);
      expect(metadata.requiresExactDecoding, isTrue);

      final DecodedImage decoded = decodeImageData(encoded);
      final ByteData samples = ByteData.sublistView(decoded.bytes);
      expect(decoded.width, 1);
      expect(decoded.height, 1);
      expect(decoded.sampleFormat, DecodedSampleFormat.float32);
      expect(decoded.colorModel, DecodedColorModel.cmyk);
      expect(samples.getFloat32(0, Endian.little), closeTo(0.125, 1e-7));
      expect(samples.getFloat32(4, Endian.little), closeTo(0.25, 1e-7));
      expect(samples.getFloat32(8, Endian.little), closeTo(0.5, 1e-7));
      expect(samples.getFloat32(12, Endian.little), closeTo(0.75, 1e-7));
      expect(samples.getFloat32(16, Endian.little), closeTo(1, 1e-7));
      expect(decoded.toImage().bytes, orderedEquals(<int>[56, 48, 32, 255]));
    });

    test('reassemble JPEG ICC segments and identify four process channels', () {
      final Uint8List profile = Uint8List.fromList(<int>[
        0x10,
        0x20,
        0x30,
        0x40,
        0x50,
        0x60,
        0x70,
      ]);
      final Uint8List encoded = _buildJpegMetadata(
        width: 7,
        height: 5,
        componentCount: 4,
        iccProfile: profile,
      );

      final DecodedImageMetadata? metadata = inspectImage(encoded);

      expect(metadata, isNotNull);
      expect(metadata!.width, 7);
      expect(metadata.height, 5);
      expect(metadata.bitsPerChannel, 8);
      expect(metadata.colorModel, DecodedColorModel.cmyk);
      expect(metadata.iccProfile, orderedEquals(profile));
    });

    test('decode a standard Adobe APP14 YCCK image as straight CMYK', () {
      final DecodedImage decoded = decodeJpgData(
        base64Decode(_ycckJpegFixture),
      );

      expect(decoded.width, 8);
      expect(decoded.height, 8);
      expect(decoded.colorModel, DecodedColorModel.cmyk);
      expect(decoded.sampleFormat, DecodedSampleFormat.uint8);
      expect(
        decoded.bytes.sublist(0, decoded.bytesPerPixel),
        orderedEquals(<int>[25, 51, 76, 102, 255]),
      );
      expect(
        decoded.toImage().bytes.sublist(0, 4),
        orderedEquals(<int>[138, 122, 107, 255]),
      );
    });

    test('inspect WebP ICC metadata without decoding its pixels', () {
      final Uint8List profile = Uint8List.fromList(<int>[
        0xaa,
        0xbb,
        0xcc,
        0xdd,
        0xee,
      ]);
      final Uint8List encoded = _buildWebPMetadata(
        width: 13,
        height: 9,
        iccProfile: profile,
      );

      final DecodedImageMetadata? metadata = inspectImage(encoded);

      expect(metadata, isNotNull);
      expect(metadata!.width, 13);
      expect(metadata.height, 9);
      expect(metadata.bitsPerChannel, 8);
      expect(metadata.colorModel, DecodedColorModel.rgb);
      expect(metadata.iccProfile, orderedEquals(profile));
      expect(
        () => inspectImage(
          encoded,
          maxIccProfileBytes: profile.lengthInBytes - 1,
        ),
        throwsA(isA<ImageCodecException>()),
      );
    });

    test('inspect bounded descriptive metadata in PNG containers', () {
      final Uint8List exif = Uint8List.fromList(<int>[0x49, 0x49, 0x2a, 0]);
      final Uint8List xmp = Uint8List.fromList(utf8.encode('<x:xmpmeta />'));
      final Uint8List encoded = _buildRgba16Png(
        red: 1,
        green: 2,
        blue: 3,
        alpha: 0xffff,
        iccProfile: Uint8List.fromList(<int>[1, 2, 3]),
        exifMetadata: exif,
        xmpMetadata: xmp,
      );

      final DecodedImageMetadata metadata = inspectImage(encoded)!;

      expect(metadata.exifMetadata, orderedEquals(exif));
      expect(metadata.xmpMetadata, orderedEquals(xmp));
      expect(
        () => inspectImage(encoded, maxDescriptiveMetadataBytes: 3),
        throwsA(isA<ImageCodecException>()),
      );
    });

    test('inspect EXIF, XMP, and IPTC resources in JPEG containers', () {
      final Uint8List exif = Uint8List.fromList(<int>[
        ...'Exif\u0000\u0000'.codeUnits,
        0x49,
        0x49,
      ]);
      final Uint8List xmp = Uint8List.fromList(utf8.encode('<rdf:RDF />'));
      final Uint8List iptc = Uint8List.fromList(<int>[0x1c, 2, 5, 0, 1, 65]);
      final Uint8List encoded = _buildJpegMetadata(
        width: 7,
        height: 5,
        componentCount: 3,
        iccProfile: Uint8List.fromList(<int>[1, 2]),
        exifMetadata: exif,
        xmpMetadata: xmp,
        iptcMetadata: iptc,
      );

      final DecodedImageMetadata metadata = inspectImage(encoded)!;

      expect(metadata.exifMetadata, orderedEquals(exif));
      expect(metadata.xmpMetadata, orderedEquals(xmp));
      expect(metadata.iptcMetadata, orderedEquals(iptc));
    });

    test('inspect EXIF and XMP chunks in WebP containers', () {
      final Uint8List exif = Uint8List.fromList(<int>[1, 3, 5]);
      final Uint8List xmp = Uint8List.fromList(utf8.encode('<x:xmpmeta />'));
      final Uint8List encoded = _buildWebPMetadata(
        width: 13,
        height: 9,
        iccProfile: Uint8List.fromList(<int>[2, 4, 6]),
        exifMetadata: exif,
        xmpMetadata: xmp,
      );

      final DecodedImageMetadata metadata = inspectImage(encoded)!;

      expect(metadata.exifMetadata, orderedEquals(exif));
      expect(metadata.xmpMetadata, orderedEquals(xmp));
      expect(
        () => metadata.xmpMetadata![0] = 0,
        throwsUnsupportedError,
      );
    });

    test('inspect IPTC and XMP tags in TIFF containers', () {
      final Uint8List iptc = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      final Uint8List xmp = Uint8List.fromList(utf8.encode('<rdf:RDF />'));
      final Uint8List encoded = _buildMetadataTiff(
        iptcMetadata: iptc,
        xmpMetadata: xmp,
      );

      final DecodedImageMetadata metadata = inspectImage(encoded)!;

      expect(metadata.width, 2);
      expect(metadata.height, 3);
      expect(metadata.iptcMetadata, orderedEquals(iptc));
      expect(metadata.xmpMetadata, orderedEquals(xmp));
    });

    test('unpremultiply TIFF samples that declare associated alpha', () {
      final Uint8List encoded = _buildEightBitTiff(
        photometric: 2,
        samplesPerPixel: 4,
        extraSample: 1,
        samples: <int>[64, 32, 16, 128],
      );

      final DecodedImage decoded = decodeTiffData(encoded);

      expect(decoded.sampleFormat, DecodedSampleFormat.uint8);
      expect(decoded.colorModel, DecodedColorModel.rgb);
      expect(decoded.bytes, orderedEquals(<int>[128, 64, 32, 128]));
    });

    test('broadcast grayscale TIFF samples and keep their alpha', () {
      final Uint8List encoded = _buildEightBitTiff(
        photometric: 1,
        samplesPerPixel: 2,
        extraSample: 2,
        samples: <int>[100, 128],
      );

      final DecodedImage decoded = decodeTiffData(encoded);

      expect(decoded.bytes, orderedEquals(<int>[100, 100, 100, 128]));
    });

    test('reject TIFF channel counts before allocating their rows', () {
      final Uint8List encoded = _buildEightBitTiff(
        photometric: 1,
        samplesPerPixel: 1,
        extraSample: 0,
        samples: <int>[42],
      );
      final ByteData data = ByteData.sublistView(encoded);
      final int entryCount = data.getUint16(8, Endian.little);
      for (int index = 0; index < entryCount; index++) {
        final int entry = 10 + index * 12;
        if (data.getUint16(entry, Endian.little) == 277) {
          data.setUint16(entry + 8, 65535, Endian.little);
          break;
        }
      }

      expect(
        () => decodeTiffData(encoded),
        throwsA(
          isA<ImageCodecException>().having(
            (error) => error.message,
            'message',
            contains('sample count'),
          ),
        ),
      );
    });

    test('reject oversized TIFF sample metadata before materializing it', () {
      final Uint8List encoded = _buildEightBitTiff(
        photometric: 5,
        samplesPerPixel: 5,
        extraSample: 2,
        samples: <int>[1, 2, 3, 4, 255],
      );
      final ByteData data = ByteData.sublistView(encoded);
      final int entryCount = data.getUint16(8, Endian.little);
      for (int index = 0; index < entryCount; index++) {
        final int entry = 10 + index * 12;
        if (data.getUint16(entry, Endian.little) == 258) {
          data.setUint32(entry + 4, 6, Endian.little);
          break;
        }
      }

      expect(
        () => inspectImage(encoded),
        throwsA(
          isA<ImageCodecException>().having(
            (error) => error.message,
            'message',
            contains('sample count'),
          ),
        ),
      );
    });

    test('reject rasters whose native samples exceed the byte budget', () {
      final Uint8List encoded = _buildCmykFloatTiff(
        cyan: 0.5,
        magenta: 0.5,
        yellow: 0.5,
        black: 0.5,
      );

      // One CMYK float32 pixel needs twenty bytes, so a nineteen-byte budget
      // must reject it even though a single pixel is well inside `maxPixels`.
      expect(
        () => decodeTiffData(encoded, maxDecodedBytes: 19),
        throwsA(isA<ImageCodecException>()),
      );
      expect(decodeTiffData(encoded, maxDecodedBytes: 20).width, 1);
    });

    test('reject data whose container is not the requested format', () {
      final Uint8List encoded = _buildEightBitTiff(
        photometric: 1,
        samplesPerPixel: 1,
        extraSample: 0,
        samples: <int>[42],
      );

      expect(() => decodePngData(encoded), throwsA(isA<ImageCodecException>()));
    });
  });
}

/// Independently encoded uniform CMYK JPEG using Adobe's YCCK transform.
const String _ycckJpegFixture =
    '/9j/7gAOQWRvYmUAZAAAAAAC/9sAQwABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB'
    'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB/9sAQwEBAQEBAQEBAQEBAQEBAQEB'
    'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB/8AAFAgA'
    'CAAIBAERAAIRAQMRAQQRAP/EABUAAQEAAAAAAAAAAAAAAAAAAAgK/8QAFBABAAAAAAAAAAAA'
    'AAAAAAAAAP/EABUBAQEAAAAAAAAAAAAAAAAAAAcI/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/a'
    'AA4EAQACEQMRBAAAPwCW9RAHMh//2Q==';

/// Creates a minimal non-interlaced one-pixel RGBA16 PNG.
Uint8List _buildRgba16Png({
  required int red,
  required int green,
  required int blue,
  required int alpha,
  required Uint8List iccProfile,
  Uint8List? exifMetadata,
  Uint8List? xmpMetadata,
}) {
  final Uint8List header = Uint8List(13);
  ByteData.sublistView(header)
    ..setUint32(0, 1, Endian.big)
    ..setUint32(4, 1, Endian.big)
    ..setUint8(8, 16)
    ..setUint8(9, 6);
  final Uint8List row = Uint8List(9);
  final ByteData rowData = ByteData.sublistView(row)
    ..setUint8(0, 0)
    ..setUint16(1, red, Endian.big)
    ..setUint16(3, green, Endian.big)
    ..setUint16(5, blue, Endian.big)
    ..setUint16(7, alpha, Endian.big);
  final Uint8List compressedProfile = Uint8List.fromList(
    const ZlibCodec().encode(iccProfile),
  );
  final Uint8List profileChunk =
      Uint8List(
          6 + compressedProfile.lengthInBytes,
        )
        ..setAll(0, 'Test'.codeUnits)
        ..setAll(6, compressedProfile);
  final BytesBuilder output = BytesBuilder(copy: false)
    ..add(const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    ..add(_pngChunk('IHDR', header))
    ..add(_pngChunk('iCCP', profileChunk));
  if (exifMetadata != null) {
    output.add(_pngChunk('eXIf', exifMetadata));
  }
  if (xmpMetadata != null) {
    output.add(
      _pngChunk(
        'iTXt',
        Uint8List.fromList(<int>[
          ...'XML:com.adobe.xmp'.codeUnits,
          0,
          0,
          0,
          0,
          0,
          ...xmpMetadata,
        ]),
      ),
    );
  }
  output
    ..add(
      _pngChunk(
        'IDAT',
        Uint8List.fromList(
          const ZlibCodec().encode(rowData.buffer.asUint8List()),
        ),
      ),
    )
    ..add(_pngChunk('IEND', Uint8List(0)));
  return output.takeBytes();
}

/// Wraps [payload] in one checksummed PNG chunk of [type].
Uint8List _pngChunk(String type, Uint8List payload) {
  final Uint8List typeBytes = Uint8List.fromList(type.codeUnits);
  final Uint8List checksumInput =
      Uint8List(
          typeBytes.lengthInBytes + payload.lengthInBytes,
        )
        ..setAll(0, typeBytes)
        ..setAll(typeBytes.lengthInBytes, payload);
  final Uint8List result = Uint8List(12 + payload.lengthInBytes);
  final ByteData data = ByteData.sublistView(result)
    ..setUint32(0, payload.lengthInBytes, Endian.big)
    ..setUint32(8 + payload.lengthInBytes, _crc32(checksumInput), Endian.big);
  result.setAll(4, typeBytes);
  result.setAll(8, payload);
  return data.buffer.asUint8List(
    result.offsetInBytes,
    result.lengthInBytes,
  );
}

/// Computes the IEEE PNG CRC-32 for [bytes].
int _crc32(Uint8List bytes) {
  int checksum = 0xffffffff;
  for (final int byte in bytes) {
    checksum ^= byte;
    for (int bit = 0; bit < 8; bit++) {
      checksum = (checksum >>> 1) ^ (checksum.isOdd ? 0xedb88320 : 0);
    }
  }
  return checksum ^ 0xffffffff;
}

/// Creates a minimal one-pixel little-endian float32 CMYK TIFF.
Uint8List _buildCmykFloatTiff({
  required double cyan,
  required double magenta,
  required double yellow,
  required double black,
}) {
  const int directoryOffset = 8;
  const int entryCount = 11;
  const int bitsOffset = directoryOffset + 2 + entryCount * 12 + 4;
  const int sampleFormatsOffset = bitsOffset + 8;
  const int pixelsOffset = sampleFormatsOffset + 8;
  final Uint8List result = Uint8List(pixelsOffset + 16);
  final ByteData data = ByteData.sublistView(result)
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, directoryOffset, Endian.little)
    ..setUint16(directoryOffset, entryCount, Endian.little);
  int entry = directoryOffset + 2;

  /// Appends one TIFF directory entry.
  void writeEntry(int tag, int type, int count, int value) {
    data
      ..setUint16(entry, tag, Endian.little)
      ..setUint16(entry + 2, type, Endian.little)
      ..setUint32(entry + 4, count, Endian.little);
    if (type == 3 && count == 1) {
      data
        ..setUint16(entry + 8, value, Endian.little)
        ..setUint16(entry + 10, 0, Endian.little);
    } else {
      data.setUint32(entry + 8, value, Endian.little);
    }
    entry += 12;
  }

  writeEntry(256, 4, 1, 1);
  writeEntry(257, 4, 1, 1);
  writeEntry(258, 3, 4, bitsOffset);
  writeEntry(259, 3, 1, 1);
  writeEntry(262, 3, 1, 5);
  writeEntry(273, 4, 1, pixelsOffset);
  writeEntry(277, 3, 1, 4);
  writeEntry(278, 4, 1, 1);
  writeEntry(279, 4, 1, 16);
  writeEntry(284, 3, 1, 1);
  writeEntry(339, 3, 4, sampleFormatsOffset);
  data.setUint32(entry, 0, Endian.little);
  for (int channel = 0; channel < 4; channel++) {
    data
      ..setUint16(bitsOffset + channel * 2, 32, Endian.little)
      ..setUint16(sampleFormatsOffset + channel * 2, 3, Endian.little);
  }
  data
    ..setFloat32(pixelsOffset, cyan, Endian.little)
    ..setFloat32(pixelsOffset + 4, magenta, Endian.little)
    ..setFloat32(pixelsOffset + 8, yellow, Endian.little)
    ..setFloat32(pixelsOffset + 12, black, Endian.little);
  return result;
}

/// Creates enough of a JPEG container to inspect its frame and ICC segments.
Uint8List _buildJpegMetadata({
  required int width,
  required int height,
  required int componentCount,
  required Uint8List iccProfile,
  Uint8List? exifMetadata,
  Uint8List? xmpMetadata,
  Uint8List? iptcMetadata,
}) {
  final int split = iccProfile.lengthInBytes ~/ 2;
  final Uint8List first = Uint8List.sublistView(iccProfile, 0, split);
  final Uint8List second = Uint8List.sublistView(
    iccProfile,
    split,
    iccProfile.lengthInBytes,
  );
  final Uint8List frame = Uint8List(6 + componentCount * 3);
  final ByteData frameData = ByteData.sublistView(frame)
    ..setUint8(0, 8)
    ..setUint16(1, height, Endian.big)
    ..setUint16(3, width, Endian.big)
    ..setUint8(5, componentCount);
  for (int component = 0; component < componentCount; component++) {
    final int offset = 6 + component * 3;
    frame
      ..[offset] = component + 1
      ..[offset + 1] = 0x11
      ..[offset + 2] = 0;
  }
  final BytesBuilder output = BytesBuilder(copy: false)..add(const <int>[0xff, 0xd8]);
  if (exifMetadata != null) {
    output.add(_jpegSegment(0xe1, exifMetadata));
  }
  if (xmpMetadata != null) {
    output.add(
      _jpegSegment(
        0xe1,
        Uint8List.fromList(<int>[
          ...'http://ns.adobe.com/xap/1.0/\u0000'.codeUnits,
          ...xmpMetadata,
        ]),
      ),
    );
  }
  if (iptcMetadata != null) {
    output.add(_jpegSegment(0xed, _photoshopIptcResource(iptcMetadata)));
  }
  output
    ..add(_jpegSegment(0xe2, _jpegIccPayload(second, 2, 2)))
    ..add(_jpegSegment(0xe2, _jpegIccPayload(first, 1, 2)))
    ..add(_jpegSegment(0xc0, frameData.buffer.asUint8List()))
    ..add(const <int>[0xff, 0xd9]);
  return output.takeBytes();
}

/// Wraps IPTC bytes in a Photoshop image-resource block.
Uint8List _photoshopIptcResource(Uint8List metadata) {
  final BytesBuilder output = BytesBuilder(copy: false)
    ..add('Photoshop 3.0\u0000'.codeUnits)
    ..add('8BIM'.codeUnits)
    ..add(const <int>[0x04, 0x04, 0, 0]);
  final Uint8List length = Uint8List(4);
  ByteData.sublistView(
    length,
  ).setUint32(0, metadata.lengthInBytes, Endian.big);
  output
    ..add(length)
    ..add(metadata);
  if (metadata.lengthInBytes.isOdd) {
    output.addByte(0);
  }
  return output.takeBytes();
}

/// Creates one JPEG APP2 ICC payload.
Uint8List _jpegIccPayload(
  Uint8List profileChunk,
  int sequence,
  int count,
) => Uint8List(14 + profileChunk.lengthInBytes)
  ..setAll(0, 'ICC_PROFILE\u0000'.codeUnits)
  ..[12] = sequence
  ..[13] = count
  ..setAll(14, profileChunk);

/// Wraps one JPEG marker payload with its two-byte encoded length.
Uint8List _jpegSegment(int marker, Uint8List payload) {
  final Uint8List result = Uint8List(payload.lengthInBytes + 4)
    ..[0] = 0xff
    ..[1] = marker
    ..setAll(4, payload);
  ByteData.sublistView(
    result,
  ).setUint16(2, payload.lengthInBytes + 2, Endian.big);
  return result;
}

/// Creates an extended WebP container carrying dimensions and an ICC chunk.
Uint8List _buildWebPMetadata({
  required int width,
  required int height,
  required Uint8List iccProfile,
  Uint8List? exifMetadata,
  Uint8List? xmpMetadata,
}) {
  final Uint8List extendedHeader = Uint8List(10)..[0] = 0x20;
  _writeUint24(extendedHeader, 4, width - 1);
  _writeUint24(extendedHeader, 7, height - 1);
  final BytesBuilder chunkBuilder = BytesBuilder(copy: false)
    ..add(_webPChunk('VP8X', extendedHeader))
    ..add(_webPChunk('ICCP', iccProfile));
  if (exifMetadata != null) {
    chunkBuilder.add(_webPChunk('EXIF', exifMetadata));
  }
  if (xmpMetadata != null) {
    chunkBuilder.add(_webPChunk('XMP ', xmpMetadata));
  }
  final Uint8List chunks = chunkBuilder.takeBytes();
  final Uint8List result = Uint8List(12 + chunks.lengthInBytes)
    ..setAll(0, 'RIFF'.codeUnits)
    ..setAll(8, 'WEBP'.codeUnits)
    ..setAll(12, chunks);
  ByteData.sublistView(
    result,
  ).setUint32(4, result.lengthInBytes - 8, Endian.little);
  return result;
}

/// Wraps [payload] in one padded WebP RIFF chunk.
Uint8List _webPChunk(String type, Uint8List payload) {
  final int paddedLength = payload.lengthInBytes + (payload.lengthInBytes & 1);
  final Uint8List result = Uint8List(8 + paddedLength)
    ..setAll(0, type.codeUnits)
    ..setAll(8, payload);
  ByteData.sublistView(
    result,
  ).setUint32(4, payload.lengthInBytes, Endian.little);
  return result;
}

/// Creates a minimal TIFF directory with descriptive metadata tags.
Uint8List _buildMetadataTiff({
  required Uint8List iptcMetadata,
  required Uint8List xmpMetadata,
}) {
  const int directoryOffset = 8;
  const int entryCount = 6;
  const int payloadOffset = directoryOffset + 2 + entryCount * 12 + 4;
  final int xmpOffset = payloadOffset + iptcMetadata.lengthInBytes;
  final Uint8List result = Uint8List(xmpOffset + xmpMetadata.lengthInBytes)
    ..setAll(payloadOffset, iptcMetadata)
    ..setAll(xmpOffset, xmpMetadata);
  final ByteData data = ByteData.sublistView(result)
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, directoryOffset, Endian.little)
    ..setUint16(directoryOffset, entryCount, Endian.little);
  int entry = directoryOffset + 2;

  /// Appends one little-endian TIFF directory entry.
  void writeEntry(int tag, int type, int count, int value) {
    data
      ..setUint16(entry, tag, Endian.little)
      ..setUint16(entry + 2, type, Endian.little)
      ..setUint32(entry + 4, count, Endian.little);
    if (type == 3 && count == 1) {
      data.setUint16(entry + 8, value, Endian.little);
    } else {
      data.setUint32(entry + 8, value, Endian.little);
    }
    entry += 12;
  }

  writeEntry(256, 4, 1, 2);
  writeEntry(257, 4, 1, 3);
  writeEntry(258, 3, 1, 8);
  writeEntry(262, 3, 1, 2);
  writeEntry(33723, 1, iptcMetadata.lengthInBytes, payloadOffset);
  writeEntry(700, 1, xmpMetadata.lengthInBytes, xmpOffset);
  data.setUint32(entry, 0, Endian.little);
  return result;
}

/// Writes one unsigned little-endian 24-bit integer.
void _writeUint24(Uint8List target, int offset, int value) {
  target
    ..[offset] = value
    ..[offset + 1] = value >>> 8
    ..[offset + 2] = value >>> 16;
}

/// Builds a one-pixel single-strip eight-bit TIFF holding [samples].
Uint8List _buildEightBitTiff({
  required int photometric,
  required int samplesPerPixel,
  required int extraSample,
  required List<int> samples,
}) {
  const int directoryOffset = 8;
  final int entryCount = extraSample == 0 ? 9 : 10;
  final int bitsOffset = directoryOffset + 2 + entryCount * 12 + 4;
  final int pixelsOffset = bitsOffset + samplesPerPixel * 2;
  final Uint8List result = Uint8List(pixelsOffset + samples.length);
  final ByteData data = ByteData.sublistView(result)
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, directoryOffset, Endian.little)
    ..setUint16(directoryOffset, entryCount, Endian.little);
  int entry = directoryOffset + 2;

  /// Appends one directory entry, storing short values inline when they fit.
  void writeEntry(int tag, int type, int count, int value) {
    data
      ..setUint16(entry, tag, Endian.little)
      ..setUint16(entry + 2, type, Endian.little)
      ..setUint32(entry + 4, count, Endian.little);
    if (type == 3 && count * 2 <= 4) {
      // Short values that fit the entry are stored inline, repeated per count.
      for (int index = 0; index < count; index++) {
        data.setUint16(entry + 8 + index * 2, value, Endian.little);
      }
    } else {
      data.setUint32(entry + 8, value, Endian.little);
    }
    entry += 12;
  }

  writeEntry(256, 4, 1, 1);
  writeEntry(257, 4, 1, 1);
  writeEntry(258, 3, samplesPerPixel, samplesPerPixel * 2 <= 4 ? 8 : bitsOffset);
  writeEntry(259, 3, 1, 1);
  writeEntry(262, 3, 1, photometric);
  writeEntry(273, 4, 1, pixelsOffset);
  writeEntry(277, 3, 1, samplesPerPixel);
  writeEntry(278, 4, 1, 1);
  writeEntry(279, 4, 1, samples.length);
  if (extraSample != 0) {
    writeEntry(338, 3, 1, extraSample);
  }
  data.setUint32(entry, 0, Endian.little);
  for (int channel = 0; channel < samplesPerPixel; channel++) {
    data.setUint16(bitsOffset + channel * 2, 8, Endian.little);
  }
  result.setAll(pixelsOffset, samples);
  return result;
}
