import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg/brotli_stored.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg/jpeg_data.dart';

/// Parses a `jbrd` box payload into a [JpegData] (everything except the quant
/// values and DCT coefficients, which come from the codestream). Faithful port
/// of libjxl `DecodeJPEGData` + `JPEGData::VisitFields`
/// (`lib/jxl/jpeg/{dec_jpeg_data,jpeg_data}.cc`): a Bundle bit-header followed
/// by a Brotli-compressed tail carrying the app/com/inter/tail byte blobs.
///
/// Throws [JpegXlUnsupportedException] for jbrd features not yet handled by the
/// grayscale-spine phase (ICC/Exif/XMP app markers, compressed Brotli tails).
JpegData decodeJbrd(Uint8List payload) {
  final br = BitReader(data: payload);
  final jpg = JpegData();
  final _BlobSizes sizes = _visitFields(br, jpg, payload.length);

  // Align to the byte boundary where the Brotli tail begins.
  final int rem = (8 - (br.bitsRead & 7)) & 7;
  if (rem != 0) {
    br.skipBits(rem);
  }
  final Uint8List tail = decodeBrotliStored(br);

  // Fill the variable-length blobs from the decompressed tail, in libjxl's
  // read order: unknown-type app markers, com markers, inter-marker data,
  // then tail data. Buffers are allocated here (bounded by the actual tail
  // length) rather than from the header's declared counts, so a crafted jbrd
  // box cannot force a large allocation before validation.
  var pos = 0;
  Uint8List take(int n) {
    if (pos + n > tail.length) {
      throw const JpegXlTruncatedException(message: 'jbrd tail shorter than declared');
    }
    final out = Uint8List.fromList(Uint8List.sublistView(tail, pos, pos + n));
    pos += n;
    return out;
  }

  for (var i = 0; i < jpg.appData.length; i++) {
    if (jpg.appMarkerType[i] != AppMarkerType.unknown) {
      // ICC/Exif/XMP payloads come from separate boxes, not the Brotli tail.
      throw JpegXlUnsupportedException(feature: 'jbrd-app-marker-injection');
    }
    final Uint8List marker = take(sizes.app[i]);
    if (marker[1] * 256 + marker[2] + 1 != marker.length) {
      throw const JpegXlInvalidBitstreamException(message: 'incorrect app marker size');
    }
    jpg.appData[i] = marker;
  }
  for (var i = 0; i < jpg.comData.length; i++) {
    final Uint8List marker = take(sizes.com[i]);
    if (marker[1] * 256 + marker[2] + 1 != marker.length) {
      throw const JpegXlInvalidBitstreamException(message: 'incorrect com marker size');
    }
    jpg.comData[i] = marker;
  }
  for (var i = 0; i < jpg.interMarkerData.length; i++) {
    jpg.interMarkerData[i] = take(sizes.inter[i]);
  }
  jpg.tailData = take(sizes.tail);

  return jpg;
}

/// Declared sizes of the Brotli-tail blobs, kept separate from [JpegData] so
/// the buffers themselves are only allocated once the tail is known.
final class _BlobSizes {
  /// Stores the app state used by the JPEG XL codec.
  ///
  final List<int> app;

  /// Stores the com state used by the JPEG XL codec.
  ///
  final List<int> com;

  /// Stores the inter state used by the JPEG XL codec.
  ///
  final List<int> inter;

  /// Stores the tail state used by the JPEG XL codec.
  ///
  final int tail;

  /// Creates an internal blob sizes.
  ///
  _BlobSizes({
    required this.app,
    required this.com,
    required this.inter,
    required this.tail,
  });
}

/// Port of `JPEGData::VisitFields` in reading mode. Returns the declared
/// blob sizes (not the buffers). [payloadLen] bounds variable counts before
/// allocation (robustness contract).
_BlobSizes _visitFields(BitReader br, JpegData jpg, int payloadLen) {
  final int maxBits = payloadLen * 8;

  br.readBool(); // is_gray — components are set by component_type below.

  // Marker order. Each marker is a 6-bit offset from 0xc0, until EOI (0xd9).
  var numApp = 0;
  var numCom = 0;
  var numScans = 0;
  var numInter = 0;
  var hasDri = false;
  final markerOrder = <int>[];
  var marker = 0xc0;
  do {
    marker = br.readBits(6) + 0xc0;
    markerOrder.add(marker);
    if (markerOrder.length > 16384) {
      throw const JpegXlInvalidBitstreamException(message: 'too many JPEG markers');
    }
    if ((marker & 0xf0) == 0xe0) {
      numApp++;
    }
    if (marker == 0xfe) {
      numCom++;
    }
    if (marker == 0xda) {
      numScans++;
    }
    if (marker == 0xff) {
      numInter++;
    }
    if (marker == 0xdd) {
      hasDri = true;
    }
  } while (marker != 0xd9);
  jpg.markerOrder = Uint8List.fromList(markerOrder);

  jpg.appData = List.generate(numApp, (_) => Uint8List(0));
  jpg.appMarkerType = List.filled(numApp, AppMarkerType.unknown);
  jpg.comData = List.generate(numCom, (_) => Uint8List(0));
  jpg.scanInfo = List.generate(numScans, (_) => JpegScanInfo());
  final appSizes = List<int>.filled(numApp, 0);
  final comSizes = List<int>.filled(numCom, 0);

  for (var i = 0; i < numApp; i++) {
    final int t = br.readU32(0, 0, 1, 0, 2, 1, 4, 2);
    if (t > 3) {
      throw JpegXlInvalidBitstreamException(message: 'unknown app marker type $t');
    }
    jpg.appMarkerType[i] = AppMarkerType.values[t];
    final int size = br.readBits(16) + 1;
    if (size < 3) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid app marker size');
    }
    appSizes[i] = size; // buffer allocated later, bounded by the tail.
  }
  for (var i = 0; i < numCom; i++) {
    final int size = br.readBits(16) + 1;
    if (size < 3) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid com marker size');
    }
    comSizes[i] = size;
  }

  // Quant tables: structure only; values come from the codestream.
  final int numQuant = br.readU32(1, 0, 2, 0, 3, 0, 4, 0);
  if (numQuant == 4) {
    throw const JpegXlInvalidBitstreamException(message: 'invalid number of quant tables');
  }
  jpg.quant = List.generate(numQuant, (_) => JpegQuantTable());
  for (var i = 0; i < numQuant; i++) {
    jpg.quant[i].precision = br.readBits(1);
    jpg.quant[i].index = br.readBits(2);
    jpg.quant[i].isLast = br.readBool();
  }

  // Components.
  final int componentType = br.readBits(2); // 0 gray, 1 ycbcr, 2 rgb, 3 custom.
  final int numComponents;
  if (componentType == 0) {
    numComponents = 1;
  } else if (componentType != 3) {
    numComponents = 3;
  } else {
    numComponents = br.readU32(1, 0, 2, 0, 3, 0, 4, 0);
    if (numComponents != 1 && numComponents != 3) {
      throw JpegXlInvalidBitstreamException(message: 'invalid number of components: $numComponents');
    }
  }
  jpg.components = List.generate(numComponents, (_) => JpegComponent());
  if (componentType == 3) {
    for (final JpegComponent c in jpg.components) {
      c.id = br.readBits(8);
    }
  } else if (componentType == 0) {
    jpg.components[0].id = 1;
  } else if (componentType == 2) {
    jpg.components[0].id = 0x52; // 'R'
    jpg.components[1].id = 0x47; // 'G'
    jpg.components[2].id = 0x42; // 'B'
  } else {
    jpg.components[0].id = 1;
    jpg.components[1].id = 2;
    jpg.components[2].id = 3;
  }
  for (final JpegComponent c in jpg.components) {
    c.quantIdx = br.readBits(2);
    if (c.quantIdx >= jpg.quant.length) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid quant table index');
    }
  }

  // Huffman tables.
  final int numHuff = br.readU32(4, 0, 2, 3, 10, 4, 26, 6);
  jpg.huffmanCode = List.generate(numHuff, (_) => JpegHuffmanCode());
  for (final JpegHuffmanCode hc in jpg.huffmanCode) {
    final bool isAc = br.readBool();
    final int id = br.readBits(2);
    hc.slotId = ((isAc ? 1 : 0) << 4) | id;
    hc.isLast = br.readBool();
    var numSymbols = 0;
    for (var i = 0; i <= 16; i++) {
      hc.counts[i] = br.readU32(0, 0, 1, 0, 2, 3, 0, 8);
      numSymbols += hc.counts[i];
    }
    if (numSymbols < 1) {
      throw const JpegXlInvalidBitstreamException(message: 'empty Huffman table');
    }
    if (numSymbols > hc.values.length) {
      throw const JpegXlInvalidBitstreamException(message: 'Huffman code too large');
    }
    // Symbols must be distinct (libjxl's value_slots duplicate check). Without
    // this a duplicated sentinel value (256) reaches the code-table builder and
    // indexes past its 256-entry arrays.
    final seen = List<bool>.filled(kJpegHuffmanAlphabetSize + 1, false);
    for (var i = 0; i < numSymbols; i++) {
      final int v = br.readU32(0, 2, 4, 2, 8, 4, 1, 8);
      if (seen[v]) {
        throw const JpegXlInvalidBitstreamException(message: 'duplicate Huffman symbol');
      }
      seen[v] = true;
      hc.values[i] = v;
    }
    if (hc.values[numSymbols - 1] != kJpegHuffmanAlphabetSize) {
      throw const JpegXlInvalidBitstreamException(message: 'missing EOI Huffman symbol');
    }
  }

  // Scan info.
  for (final JpegScanInfo scan in jpg.scanInfo) {
    scan.numComponents = br.readU32(1, 0, 2, 0, 3, 0, 4, 0);
    if (scan.numComponents >= 4) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid scan component count');
    }
    scan.ss = br.readBits(6);
    scan.se = br.readBits(6);
    scan.al = br.readBits(4);
    scan.ah = br.readBits(4);
    for (var i = 0; i < scan.numComponents; i++) {
      final JpegComponentScanInfo ci = scan.components[i];
      ci.compIdx = br.readBits(2);
      if (ci.compIdx >= jpg.components.length) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid scan component idx');
      }
      ci.acTblIdx = br.readBits(2);
      ci.dcTblIdx = br.readBits(2);
    }
    scan.lastNeededPass = br.readU32(0, 0, 1, 0, 2, 0, 3, 3);
  }

  // Bit-exact reconstruction extras.
  if (hasDri) {
    jpg.restartInterval = br.readBits(16);
  }
  for (final JpegScanInfo scan in jpg.scanInfo) {
    final int numResetPoints = br.readU32(0, 0, 1, 2, 4, 4, 20, 16);
    scan.resetPoints = Uint32List(numResetPoints);
    var lastBlockIdx = -1;
    for (var i = 0; i < numResetPoints; i++) {
      final int blockIdx = br.readU32(0, 0, 1, 3, 9, 5, 41, 28) + lastBlockIdx + 1;
      if (blockIdx >= (3 << 26)) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid reset-point block');
      }
      scan.resetPoints[i] = blockIdx;
      lastBlockIdx = blockIdx;
    }

    final int numExtra = br.readU32(0, 0, 1, 2, 4, 4, 20, 16);
    final extras = <({int blockIdx, int numExtraZeroRuns})>[];
    lastBlockIdx = -1;
    for (var i = 0; i < numExtra; i++) {
      final int numRuns = br.readU32(1, 0, 2, 2, 5, 4, 20, 8);
      final int blockIdx = br.readU32(0, 0, 1, 3, 9, 5, 41, 28) + lastBlockIdx + 1;
      if (blockIdx > (3 << 26)) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid extra-zero block');
      }
      extras.add((blockIdx: blockIdx, numExtraZeroRuns: numRuns));
      lastBlockIdx = blockIdx;
    }
    scan.extraZeroRuns = extras;
  }

  final interSizes = Uint32List(numInter);
  for (var i = 0; i < numInter; i++) {
    interSizes[i] = br.readBits(16);
  }
  final int tailDataLen = br.readU32(0, 0, 1, 8, 257, 16, 65793, 22);

  jpg.hasZeroPaddingBit = br.readBool();
  if (jpg.hasZeroPaddingBit) {
    final int nbit = br.readBits(24);
    if (nbit > maxBits) {
      throw const JpegXlTruncatedException(message: 'padding-bit count exceeds box');
    }
    jpg.paddingBits = Uint8List(nbit);
    for (var i = 0; i < nbit; i++) {
      jpg.paddingBits[i] = br.readBool() ? 1 : 0;
    }
  }

  // Postponed sizing; the caller allocates and fills these from the Brotli
  // tail (bounded by the actual tail length).
  jpg.interMarkerData = List.generate(numInter, (_) => Uint8List(0));
  return _BlobSizes(app: appSizes, com: comSizes, inter: interSizes.toList(), tail: tailDataLen);
}
