import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';

/// Result of container demuxing: the raw codestream plus container metadata.
final class DemuxedStream {
  /// The bare codestream (starts with 0xFF 0x0A).
  final Uint8List codestream;

  /// Conformance level from the `jxll` box; 5 when absent.
  final int level;

  /// Whether the input was wrapped in an ISOBMFF container.
  final bool isContainer;

  /// Payload of the JPEG bitstream reconstruction-data box, when present.
  /// Only JPEG-transcoded files carry this `jbrd` box.
  final Uint8List? jpegReconstructionData;

  /// Creates a demuxed stream.
  const DemuxedStream._({
    required this.codestream,
    required this.level,
    required this.isContainer,
    this.jpegReconstructionData,
  });
}

/// JPEG XL container signature bytes.
const _containerSignature = [
  0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, // ....JXL(space)
  0x0D, 0x0A, 0x87, 0x0A,
];

/// Whether [bytes] start with a JPEG XL signature — the bare codestream
/// marker (`FF 0A`) or the 12-byte ISOBMFF container signature box.
/// A cheap prefix check for routing bytes of mixed image formats to the
/// right decoder; it validates nothing beyond the signature (a `true` can
/// still fail to decode — use `JpegXlCodestreamInfo.parse` to actually inspect the
/// file). Never throws, whatever the input length.
bool looksLikeJpegXl(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0x0A) {
    return true;
  }
  if (bytes.length < _containerSignature.length) {
    return false;
  }
  for (var i = 0; i < _containerSignature.length; i++) {
    if (bytes[i] != _containerSignature[i]) {
      return false;
    }
  }
  return true;
}

/// Extracts the codestream from [data], which may be a bare codestream or an
/// ISOBMFF container with `jxlc`/`jxlp` boxes. Unknown boxes are skipped.
DemuxedStream demuxContainer(Uint8List data) {
  if (data.length >= 2 && data[0] == 0xFF && data[1] == 0x0A) {
    return DemuxedStream._(codestream: data, level: 5, isContainer: false);
  }
  if (data.length < 12) {
    throw const JpegXlTruncatedException(message: 'input shorter than any JXL signature');
  }
  for (var i = 0; i < 12; i++) {
    if (data[i] != _containerSignature[i]) {
      throw const JpegXlInvalidBitstreamException(message: 'not a JPEG XL file');
    }
  }

  final byteData = ByteData.sublistView(data);
  var level = 5;
  Uint8List? jpegReconstructionData;
  final parts = <Uint8List>[];
  var offset = 12;
  while (offset < data.length) {
    if (offset + 8 > data.length) {
      throw const JpegXlTruncatedException(message: 'truncated box header');
    }
    final int size32 = byteData.getUint32(offset);
    final tag = String.fromCharCodes(data, offset + 4, offset + 8);
    int payloadStart = offset + 8;
    final int payloadEnd;
    if (size32 == 1) {
      if (offset + 16 > data.length) {
        throw const JpegXlTruncatedException(message: 'truncated extended box size');
      }
      // Two 32-bit reads instead of getUint64, which dart2js doesn't
      // implement (throws); wideShl keeps the combine safe past 32 bits.
      final int size64 = wideShl(byteData.getUint32(offset + 8), 32) + byteData.getUint32(offset + 12);
      payloadStart = offset + 16;
      payloadEnd = offset + size64;
    } else if (size32 == 0) {
      // Box extends to the end of the file.
      payloadEnd = data.length;
    } else {
      payloadEnd = offset + size32;
    }
    if (payloadEnd < payloadStart) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal box size');
    }
    if (payloadEnd > data.length) {
      throw const JpegXlTruncatedException(message: 'box extends past end of input');
    }

    switch (tag) {
      case 'jxll':
        if (payloadEnd - payloadStart != 1) {
          throw const JpegXlInvalidBitstreamException(message: 'jxll box must have size 1');
        }
        level = data[payloadStart];
        if (level != 5 && level != 10) {
          throw JpegXlInvalidBitstreamException(message: 'invalid level: $level');
        }
      case 'jxlc':
        parts.add(Uint8List.sublistView(data, payloadStart, payloadEnd));
      case 'jxlp':
        // Partial codestream: 4-byte sequence number, then payload. The
        // sequence numbers are required to be in order, so concatenation in
        // file order is correct.
        if (payloadEnd - payloadStart < 4) {
          throw const JpegXlInvalidBitstreamException(message: 'jxlp box too small');
        }
        parts.add(Uint8List.sublistView(data, payloadStart + 4, payloadEnd));
      case 'jbrd':
        jpegReconstructionData = Uint8List.sublistView(data, payloadStart, payloadEnd);
      default:
        break; // Exif, xml , brob, ftyp, ... — skipped.
    }
    offset = payloadEnd;
  }

  if (parts.isEmpty) {
    throw const JpegXlInvalidBitstreamException(message: 'container has no codestream');
  }
  final Uint8List codestream;
  if (parts.length == 1) {
    codestream = parts[0];
  } else {
    final int total = parts.fold(0, (sum, p) => sum + p.length);
    codestream = Uint8List(total);
    var pos = 0;
    for (final part in parts) {
      codestream.setAll(pos, part);
      pos += part.length;
    }
  }
  return DemuxedStream._(
    codestream: codestream,
    level: level,
    isContainer: true,
    jpegReconstructionData: jpegReconstructionData,
  );
}

/// Extracts as much of the codestream as [data] (a growing prefix of a JXL
/// file) currently contains. Never throws on truncation inside boxes; a
/// buffer too short to identify the signature throws [JpegXlTruncatedException]
/// and non-JXL data throws [JpegXlInvalidBitstreamException].
Uint8List demuxContainerPartial(Uint8List data) {
  if (data.length >= 2 && data[0] == 0xFF && data[1] == 0x0A) {
    return data;
  }
  if (data.length < 12) {
    throw const JpegXlTruncatedException(message: 'input shorter than any JXL signature');
  }
  for (var i = 0; i < 12; i++) {
    if (data[i] != _containerSignature[i]) {
      throw const JpegXlInvalidBitstreamException(message: 'not a JPEG XL file');
    }
  }
  final byteData = ByteData.sublistView(data);
  final parts = <Uint8List>[];
  var offset = 12;
  while (offset < data.length) {
    if (offset + 8 > data.length) {
      break;
    }
    final int size32 = byteData.getUint32(offset);
    final tag = String.fromCharCodes(data, offset + 4, offset + 8);
    int payloadStart = offset + 8;
    final int payloadEnd;
    if (size32 == 1) {
      if (offset + 16 > data.length) {
        break;
      }
      payloadStart = offset + 16;
      payloadEnd = offset + byteData.getUint64(offset + 8);
    } else if (size32 == 0) {
      payloadEnd = data.length; // extends to end of file / stream so far
    } else {
      payloadEnd = offset + size32;
    }
    if (payloadEnd < payloadStart) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal box size');
    }
    final bool isCodestream = tag == 'jxlc' || tag == 'jxlp';
    if (payloadEnd > data.length) {
      // Truncated box: a codestream box still contributes its prefix.
      if (isCodestream) {
        var start = payloadStart;
        if (tag == 'jxlp') {
          start += 4;
        }
        if (start < data.length) {
          parts.add(Uint8List.sublistView(data, start));
        }
      }
      break;
    }
    if (isCodestream) {
      var start = payloadStart;
      if (tag == 'jxlp') {
        if (payloadEnd - payloadStart < 4) {
          throw const JpegXlInvalidBitstreamException(message: 'jxlp box too small');
        }
        start += 4;
      }
      parts.add(Uint8List.sublistView(data, start, payloadEnd));
    }
    offset = payloadEnd;
  }
  if (parts.isEmpty) {
    throw const JpegXlTruncatedException(message: 'no codestream bytes yet');
  }
  if (parts.length == 1) {
    return parts[0];
  }
  final int total = parts.fold(0, (sum, p) => sum + p.length);
  final codestream = Uint8List(total);
  var pos = 0;
  for (final part in parts) {
    codestream.setAll(pos, part);
    pos += part.length;
  }
  return codestream;
}
