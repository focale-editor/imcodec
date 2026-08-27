import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/brotli_stored_decoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_reconstruction_data.dart';

/// Parses a `jbrd` box into JPEG reconstruction data.
/// Quantization values and DCT coefficients come from the codestream rather
/// than this payload. The supported subset accepts verbatim application,
/// comment, inter-marker, and trailing blobs stored in uncompressed Brotli
/// blocks. Specialized marker injection and compressed Brotli blocks throw
/// [JpegXlUnsupportedException].
JpegReconstructionData decodeJpegReconstructionData(Uint8List payload) {
  final BitReader reader = BitReader(data: payload);
  final JpegReconstructionData reconstructionData = JpegReconstructionData();
  final _ReconstructionBlobSizes sizes = _readReconstructionFields(reader, reconstructionData, payload.length);

  // Align to the byte boundary where the Brotli tail begins.
  final int alignmentBitCount = (8 - (reader.bitsRead & 7)) & 7;
  if (alignmentBitCount != 0) {
    reader.skipBits(alignmentBitCount);
  }
  final Uint8List tail = decodeStoredBrotliStream(reader);

  // Fill the variable-length blobs from the decompressed tail, in libjxl's
  // read order: unknown-type app markers, com markers, inter-marker data,
  // then tail data. Buffers are allocated here (bounded by the actual tail
  // length) rather than from the header's declared counts, so a crafted jbrd
  // box cannot force a large allocation before validation.
  int tailPosition = 0;
  Uint8List takeBytes(int byteCount) {
    if (tailPosition + byteCount > tail.length) {
      throw const JpegXlTruncatedException(message: 'jbrd tail shorter than declared');
    }
    final Uint8List result = Uint8List.fromList(Uint8List.sublistView(tail, tailPosition, tailPosition + byteCount));
    tailPosition += byteCount;
    return result;
  }

  for (int markerIndex = 0; markerIndex < reconstructionData.applicationMarkerData.length; markerIndex++) {
    if (reconstructionData.applicationMarkerTypes[markerIndex] != JpegApplicationMarkerType.unknown) {
      // ICC/Exif/XMP payloads come from separate boxes, not the Brotli tail.
      throw JpegXlUnsupportedException(feature: 'jbrd-app-marker-injection');
    }
    final Uint8List marker = takeBytes(sizes.applicationMarkerSizes[markerIndex]);
    if (marker[1] * 256 + marker[2] + 1 != marker.length) {
      throw const JpegXlInvalidBitstreamException(message: 'incorrect application-marker size');
    }
    reconstructionData.applicationMarkerData[markerIndex] = marker;
  }
  for (int markerIndex = 0; markerIndex < reconstructionData.commentMarkerData.length; markerIndex++) {
    final Uint8List marker = takeBytes(sizes.commentMarkerSizes[markerIndex]);
    if (marker[1] * 256 + marker[2] + 1 != marker.length) {
      throw const JpegXlInvalidBitstreamException(message: 'incorrect comment-marker size');
    }
    reconstructionData.commentMarkerData[markerIndex] = marker;
  }
  for (int markerIndex = 0; markerIndex < reconstructionData.interMarkerData.length; markerIndex++) {
    reconstructionData.interMarkerData[markerIndex] = takeBytes(sizes.interMarkerSizes[markerIndex]);
  }
  reconstructionData.trailingData = takeBytes(sizes.trailingDataSize);

  return reconstructionData;
}

/// Stores validated lengths for variable blobs in the Brotli tail.
/// Keeping lengths separate delays buffer allocation until the decoded tail is
/// available and bounded.
final class _ReconstructionBlobSizes {
  /// Declared size of each application-marker payload.
  final List<int> applicationMarkerSizes;

  /// Declared size of each comment-marker payload.
  final List<int> commentMarkerSizes;

  /// Declared size of each inter-marker payload.
  final List<int> interMarkerSizes;

  /// Declared number of trailing bytes.
  final int trailingDataSize;

  /// Creates a validated set of declared payload sizes.
  _ReconstructionBlobSizes({
    required this.applicationMarkerSizes,
    required this.commentMarkerSizes,
    required this.interMarkerSizes,
    required this.trailingDataSize,
  });
}

/// Reads fixed reconstruction fields and returns declared blob lengths.
/// [payloadLength] bounds variable counts before any corresponding allocation.
_ReconstructionBlobSizes _readReconstructionFields(BitReader reader, JpegReconstructionData reconstructionData, int payloadLength) {
  final int maximumBitCount = payloadLength * 8;

  reader.readBool(); // is_gray — components are set by component_type below.

  // Marker order. Each marker is a 6-bit offset from 0xc0, until EOI (0xd9).
  int applicationMarkerCount = 0;
  int commentMarkerCount = 0;
  int scanCount = 0;
  int interMarkerCount = 0;
  bool hasRestartInterval = false;
  final List<int> markerOrder = <int>[];
  int marker = 0xc0;
  do {
    marker = reader.readBits(6) + 0xc0;
    markerOrder.add(marker);
    if (markerOrder.length > 16384) {
      throw const JpegXlInvalidBitstreamException(message: 'too many JPEG markers');
    }
    if ((marker & 0xf0) == 0xe0) {
      applicationMarkerCount++;
    }
    if (marker == 0xfe) {
      commentMarkerCount++;
    }
    if (marker == 0xda) {
      scanCount++;
    }
    if (marker == 0xff) {
      interMarkerCount++;
    }
    if (marker == 0xdd) {
      hasRestartInterval = true;
    }
  } while (marker != 0xd9);
  reconstructionData.markerOrder = Uint8List.fromList(markerOrder);

  reconstructionData.applicationMarkerData = List.generate(applicationMarkerCount, (_) => Uint8List(0));
  reconstructionData.applicationMarkerTypes = List.filled(applicationMarkerCount, JpegApplicationMarkerType.unknown);
  reconstructionData.commentMarkerData = List.generate(commentMarkerCount, (_) => Uint8List(0));
  reconstructionData.scans = List.generate(scanCount, (_) => JpegScan());
  final List<int> applicationMarkerSizes = List<int>.filled(applicationMarkerCount, 0);
  final List<int> commentMarkerSizes = List<int>.filled(commentMarkerCount, 0);

  for (int markerIndex = 0; markerIndex < applicationMarkerCount; markerIndex++) {
    final int markerType = reader.readU32(0, 0, 1, 0, 2, 1, 4, 2);
    if (markerType > 3) {
      throw JpegXlInvalidBitstreamException(message: 'unknown application-marker type $markerType');
    }
    reconstructionData.applicationMarkerTypes[markerIndex] = JpegApplicationMarkerType.values[markerType];
    final int size = reader.readBits(16) + 1;
    if (size < 3) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid application-marker size');
    }
    applicationMarkerSizes[markerIndex] = size; // buffer allocated later, bounded by the tail.
  }
  for (int markerIndex = 0; markerIndex < commentMarkerCount; markerIndex++) {
    final int size = reader.readBits(16) + 1;
    if (size < 3) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid comment-marker size');
    }
    commentMarkerSizes[markerIndex] = size;
  }

  // Quant tables: structure only; values come from the codestream.
  final int quantizationTableCount = reader.readU32(1, 0, 2, 0, 3, 0, 4, 0);
  if (quantizationTableCount == 4) {
    throw const JpegXlInvalidBitstreamException(message: 'invalid number of quantization tables');
  }
  reconstructionData.quantizationTables = List.generate(quantizationTableCount, (_) => JpegQuantizationTable());
  for (int tableIndex = 0; tableIndex < quantizationTableCount; tableIndex++) {
    reconstructionData.quantizationTables[tableIndex].precision = reader.readBits(1);
    reconstructionData.quantizationTables[tableIndex].index = reader.readBits(2);
    reconstructionData.quantizationTables[tableIndex].isLast = reader.readBool();
  }

  // Components.
  final int componentType = reader.readBits(2); // 0 gray, 1 ycbcr, 2 rgb, 3 custom.
  final int componentCount;
  if (componentType == 0) {
    componentCount = 1;
  } else if (componentType != 3) {
    componentCount = 3;
  } else {
    componentCount = reader.readU32(1, 0, 2, 0, 3, 0, 4, 0);
    if (componentCount != 1 && componentCount != 3) {
      throw JpegXlInvalidBitstreamException(message: 'invalid number of components: $componentCount');
    }
  }
  reconstructionData.components = List.generate(componentCount, (_) => JpegComponent());
  if (componentType == 3) {
    for (final JpegComponent component in reconstructionData.components) {
      component.identifier = reader.readBits(8);
    }
  } else if (componentType == 0) {
    reconstructionData.components[0].identifier = 1;
  } else if (componentType == 2) {
    reconstructionData.components[0].identifier = 0x52; // 'R'
    reconstructionData.components[1].identifier = 0x47; // 'G'
    reconstructionData.components[2].identifier = 0x42; // 'B'
  } else {
    reconstructionData.components[0].identifier = 1;
    reconstructionData.components[1].identifier = 2;
    reconstructionData.components[2].identifier = 3;
  }
  for (final JpegComponent component in reconstructionData.components) {
    component.quantizationTableIndex = reader.readBits(2);
    if (component.quantizationTableIndex >= reconstructionData.quantizationTables.length) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid quantization-table index');
    }
  }

  // Huffman tables.
  final int huffmanTableCount = reader.readU32(4, 0, 2, 3, 10, 4, 26, 6);
  reconstructionData.huffmanTables = List.generate(huffmanTableCount, (_) => JpegHuffmanTable());
  for (final JpegHuffmanTable huffmanTable in reconstructionData.huffmanTables) {
    final bool isAcTable = reader.readBool();
    final int identifier = reader.readBits(2);
    huffmanTable.slotIdentifier = ((isAcTable ? 1 : 0) << 4) | identifier;
    huffmanTable.isLast = reader.readBool();
    int symbolCount = 0;
    for (int codeLength = 0; codeLength <= jpegHuffmanMaximumBitLength; codeLength++) {
      huffmanTable.counts[codeLength] = reader.readU32(0, 0, 1, 0, 2, 3, 0, 8);
      symbolCount += huffmanTable.counts[codeLength];
    }
    if (symbolCount < 1) {
      throw const JpegXlInvalidBitstreamException(message: 'empty Huffman table');
    }
    if (symbolCount > huffmanTable.values.length) {
      throw const JpegXlInvalidBitstreamException(message: 'Huffman code too large');
    }
    // Symbols must be distinct (libjxl's value_slots duplicate check). Without
    // this a duplicated sentinel value (256) reaches the code-table builder and
    // indexes past its 256-entry arrays.
    final List<bool> seenSymbols = List<bool>.filled(jpegHuffmanAlphabetSize + 1, false);
    for (int symbolIndex = 0; symbolIndex < symbolCount; symbolIndex++) {
      final int symbol = reader.readU32(0, 2, 4, 2, 8, 4, 1, 8);
      if (seenSymbols[symbol]) {
        throw const JpegXlInvalidBitstreamException(message: 'duplicate Huffman symbol');
      }
      seenSymbols[symbol] = true;
      huffmanTable.values[symbolIndex] = symbol;
    }
    if (huffmanTable.values[symbolCount - 1] != jpegHuffmanAlphabetSize) {
      throw const JpegXlInvalidBitstreamException(message: 'missing EOI Huffman symbol');
    }
  }

  // Scan info.
  for (final JpegScan scan in reconstructionData.scans) {
    scan.componentCount = reader.readU32(1, 0, 2, 0, 3, 0, 4, 0);
    if (scan.componentCount >= 4) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid scan component count');
    }
    scan.spectralStart = reader.readBits(6);
    scan.spectralEnd = reader.readBits(6);
    scan.successiveApproximationLow = reader.readBits(4);
    scan.successiveApproximationHigh = reader.readBits(4);
    for (int componentIndex = 0; componentIndex < scan.componentCount; componentIndex++) {
      final JpegScanComponent scanComponent = scan.components[componentIndex];
      scanComponent.componentIndex = reader.readBits(2);
      if (scanComponent.componentIndex >= reconstructionData.components.length) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid scan component index');
      }
      scanComponent.acTableIndex = reader.readBits(2);
      scanComponent.dcTableIndex = reader.readBits(2);
    }
    scan.finalRequiredPass = reader.readU32(0, 0, 1, 0, 2, 0, 3, 3);
  }

  // Bit-exact reconstruction extras.
  if (hasRestartInterval) {
    reconstructionData.restartInterval = reader.readBits(16);
  }
  for (final JpegScan scan in reconstructionData.scans) {
    final int resetPointCount = reader.readU32(0, 0, 1, 2, 4, 4, 20, 16);
    scan.resetPoints = Uint32List(resetPointCount);
    int lastBlockIndex = -1;
    for (int resetPointIndex = 0; resetPointIndex < resetPointCount; resetPointIndex++) {
      final int blockIndex = reader.readU32(0, 0, 1, 3, 9, 5, 41, 28) + lastBlockIndex + 1;
      if (blockIndex >= (3 << 26)) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid reset-point block');
      }
      scan.resetPoints[resetPointIndex] = blockIndex;
      lastBlockIndex = blockIndex;
    }

    final int extraEntryCount = reader.readU32(0, 0, 1, 2, 4, 4, 20, 16);
    final List<({int blockIndex, int extraZeroRunCount})> extraZeroRuns = <({int blockIndex, int extraZeroRunCount})>[];
    lastBlockIndex = -1;
    for (int extraEntryIndex = 0; extraEntryIndex < extraEntryCount; extraEntryIndex++) {
      final int extraZeroRunCount = reader.readU32(1, 0, 2, 2, 5, 4, 20, 8);
      final int blockIndex = reader.readU32(0, 0, 1, 3, 9, 5, 41, 28) + lastBlockIndex + 1;
      if (blockIndex > (3 << 26)) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid extra-zero block');
      }
      extraZeroRuns.add((blockIndex: blockIndex, extraZeroRunCount: extraZeroRunCount));
      lastBlockIndex = blockIndex;
    }
    scan.extraZeroRuns = extraZeroRuns;
  }

  final Uint32List interMarkerSizes = Uint32List(interMarkerCount);
  for (int markerIndex = 0; markerIndex < interMarkerCount; markerIndex++) {
    interMarkerSizes[markerIndex] = reader.readBits(16);
  }
  final int trailingDataSize = reader.readU32(0, 0, 1, 8, 257, 16, 65793, 22);

  reconstructionData.preservesZeroPaddingBits = reader.readBool();
  if (reconstructionData.preservesZeroPaddingBits) {
    final int paddingBitCount = reader.readBits(24);
    if (paddingBitCount > maximumBitCount) {
      throw const JpegXlTruncatedException(message: 'padding-bit count exceeds box');
    }
    reconstructionData.entropyPaddingBits = Uint8List(paddingBitCount);
    for (int bitIndex = 0; bitIndex < paddingBitCount; bitIndex++) {
      reconstructionData.entropyPaddingBits[bitIndex] = reader.readBool() ? 1 : 0;
    }
  }

  // Postponed sizing; the caller allocates and fills these from the Brotli
  // tail (bounded by the actual tail length).
  reconstructionData.interMarkerData = List.generate(interMarkerCount, (_) => Uint8List(0));
  return _ReconstructionBlobSizes(
    applicationMarkerSizes: applicationMarkerSizes,
    commentMarkerSizes: commentMarkerSizes,
    interMarkerSizes: interMarkerSizes.toList(),
    trailingDataSize: trailingDataSize,
  );
}
