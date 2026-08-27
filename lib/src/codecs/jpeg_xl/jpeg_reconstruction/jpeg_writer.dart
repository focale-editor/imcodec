import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_reconstruction_data.dart';

/// Re-emits the original JPEG bytes from fully populated reconstruction data.
/// [reconstructionData] combines marker structure from the `jbrd` box with
/// quantization values and coefficients recovered from the JPEG XL codestream.
/// Adapted from libjxl's `lib/jxl/jpeg/dec_jpeg_data_writer.cc` baseline
/// sequential path. Progressive scans are outside the supported subset.
Uint8List writeJpeg(JpegReconstructionData reconstructionData) {
  final _JpegSerializationState state = _JpegSerializationState(reconstructionData: reconstructionData);
  final BytesBuilder output = BytesBuilder(copy: false);

  output.add(Uint8List.fromList(const [0xFF, JpegMarker.startOfImage]));
  for (final int marker in reconstructionData.markerOrder) {
    _serializeSection(marker, state, output);
  }
  if (state.entropyPaddingBits != null && state.entropyPaddingBitPosition != reconstructionData.entropyPaddingBits.length) {
    throw const JpegXlInvalidBitstreamException(message: 'unused JPEG padding bits');
  }
  return output.toBytes();
}

/// MSB-first bit accumulator with JPEG 0xFF byte-stuffing. Reconstruction is
/// an archival path (not the decode hot loop), so a simple accumulator is used
/// rather than libjxl's 64-bit-word writer.
final class _JpegBitWriter {
  /// Destination receiving emitted entropy bytes.
  final BytesBuilder _output;

  /// Pending entropy bits waiting to form a complete byte.
  int _accumulator = 0;

  /// Number of valid low-order bits held in [_accumulator].
  int _bitCount = 0;

  /// Writes entropy-coded JPEG data into [_output].
  _JpegBitWriter({
    required this._output,
  });

  /// Writes the requested low-order bits.
  void writeBits(int bitCount, int value) {
    if (bitCount == 0) {
      return;
    }
    _accumulator = (_accumulator << bitCount) | (value & ((1 << bitCount) - 1));
    _bitCount += bitCount;
    while (_bitCount >= 8) {
      _bitCount -= 8;
      final int outputByte = (_accumulator >> _bitCount) & 0xFF;
      _output.addByte(outputByte);
      if (outputByte == 0xFF) {
        _output.addByte(0x00);
      }
    }
    _accumulator &= (1 << _bitCount) - 1;
  }

  /// Writes one entropy-coded symbol.
  void writeSymbol(int symbol, JpegHuffmanCodeTable table) {
    writeBits(table.bitLengths[symbol], table.codes[symbol]);
  }

  /// Pads to the next byte boundary. When [entropyPaddingBits] is null, pads with 1-bits;
  /// otherwise consumes the exact stored padding bits. Returns the new
  /// pad-bit cursor.
  int padToByteBoundary(Uint8List? entropyPaddingBits, int initialPadPosition, int padEnd) {
    int paddingBitPosition = initialPadPosition;
    final int requiredBitCount = (8 - (_bitCount & 7)) & 7;
    if (requiredBitCount == 0) {
      return paddingBitPosition;
    }
    int pattern;
    if (entropyPaddingBits == null) {
      pattern = (1 << requiredBitCount) - 1;
    } else {
      pattern = 0;
      for (var i = 0; i < requiredBitCount; i++) {
        if (paddingBitPosition >= padEnd) {
          throw const JpegXlInvalidBitstreamException(message: 'too few JPEG padding bits');
        }
        final int bit = entropyPaddingBits[paddingBitPosition++];
        pattern = (pattern << 1) | bit;
      }
    }
    writeBits(requiredBitCount, pattern);
    return paddingBitPosition;
  }
}

/// Tracks marker and entropy state while reconstructing a JPEG file.
final class _JpegSerializationState {
  /// Parsed structure and coefficients being serialized.
  final JpegReconstructionData reconstructionData;

  /// Canonical Huffman tables used for DC coefficients.
  final List<JpegHuffmanCodeTable> dcHuffmanTables = List.generate(4, (_) => JpegHuffmanCodeTable());

  /// Canonical Huffman tables used for AC coefficients.
  final List<JpegHuffmanCodeTable> acHuffmanTables = List.generate(4, (_) => JpegHuffmanCodeTable());

  /// Next quantization-table definition to serialize.
  int quantizationTableSegmentIndex = 0;

  /// Next Huffman-table definition to serialize.
  int huffmanTableSegmentIndex = 0;

  /// Next application-marker payload to serialize.
  int applicationMarkerIndex = 0;

  /// Next comment-marker payload to serialize.
  int commentMarkerIndex = 0;

  /// Next verbatim inter-marker payload to serialize.
  int interMarkerDataIndex = 0;

  /// Next entropy-coded scan to serialize.
  int scanIndex = 0;

  /// Whether the current frame uses progressive entropy coding.
  bool isProgressive = false;

  /// Whether a restart-interval marker has already been emitted.
  bool hasWrittenRestartInterval = false;

  /// Source padding bits preserved for byte-exact reconstruction, when needed.
  Uint8List? entropyPaddingBits;

  /// Position of the next preserved bit in [entropyPaddingBits].
  int entropyPaddingBitPosition = 0;

  /// Creates serialization state for [reconstructionData].
  _JpegSerializationState({
    required this.reconstructionData,
  }) {
    if (reconstructionData.preservesZeroPaddingBits) {
      entropyPaddingBits = reconstructionData.entropyPaddingBits;
    }
  }
}

/// Serializes the section represented by [marker].
void _serializeSection(int marker, _JpegSerializationState state, BytesBuilder output) {
  switch (marker) {
    case JpegMarker.startOfFrameBaseline:
    case JpegMarker.startOfFrameExtended:
    case JpegMarker.startOfFrameProgressive:
    case JpegMarker.startOfFrameArithmeticExtended:
    case JpegMarker.startOfFrameArithmeticProgressive:
      _writeStartOfFrame(marker, state, output);
    case JpegMarker.defineHuffmanTable:
      _writeHuffmanTables(state, output);
    case >= JpegMarker.restart0 && <= JpegMarker.restart7:
      output.add(Uint8List.fromList([0xFF, marker]));
    case JpegMarker.endOfImage:
      output.add(Uint8List.fromList(const [0xFF, JpegMarker.endOfImage]));
      output.add(state.reconstructionData.trailingData);
    case JpegMarker.startOfScan:
      _writeScan(state, output);
    case JpegMarker.defineQuantizationTable:
      _writeQuantizationTables(state, output);
    case JpegMarker.defineRestartInterval:
      state.hasWrittenRestartInterval = true;
      final int restartInterval = state.reconstructionData.restartInterval;
      output.add(Uint8List.fromList([0xFF, JpegMarker.defineRestartInterval, 0, 4, restartInterval >> 8, restartInterval & 0xFF]));
    case >= JpegMarker.application0 && <= JpegMarker.application15:
      final int markerIndex = state.applicationMarkerIndex++;
      output.addByte(0xFF);
      output.add(state.reconstructionData.applicationMarkerData[markerIndex]);
    case JpegMarker.comment:
      final int markerIndex = state.commentMarkerIndex++;
      output.addByte(0xFF);
      output.add(state.reconstructionData.commentMarkerData[markerIndex]);
    case 0xFF:
      output.add(state.reconstructionData.interMarkerData[state.interMarkerDataIndex++]);
    default:
      throw JpegXlInvalidBitstreamException(message: 'unexpected JPEG marker 0x${marker.toRadixString(16)}');
  }
}

/// Writes a start-of-frame segment for [marker].
void _writeStartOfFrame(int marker, _JpegSerializationState state, BytesBuilder output) {
  if (marker <= 0xC2) {
    state.isProgressive = marker == JpegMarker.startOfFrameProgressive;
  }
  final JpegReconstructionData reconstructionData = state.reconstructionData;
  final int componentCount = reconstructionData.components.length;
  final int segmentLength = 8 + 3 * componentCount;
  final Uint8List data = Uint8List(segmentLength + 2);
  int position = 0;
  data[position++] = 0xFF;
  data[position++] = marker;
  data[position++] = segmentLength >> 8;
  data[position++] = segmentLength & 0xFF;
  data[position++] = 8; // precision
  data[position++] = reconstructionData.height >> 8;
  data[position++] = reconstructionData.height & 0xFF;
  data[position++] = reconstructionData.width >> 8;
  data[position++] = reconstructionData.width & 0xFF;
  data[position++] = componentCount;
  for (final JpegComponent component in reconstructionData.components) {
    data[position++] = component.identifier;
    data[position++] = (component.horizontalSamplingFactor << 4) | component.verticalSamplingFactor;
    data[position++] = reconstructionData.quantizationTables[component.quantizationTableIndex].index;
  }
  output.add(data);
}

/// Writes the start-of-scan segment for [scan].
void _writeStartOfScan(JpegScan scan, _JpegSerializationState state, BytesBuilder output) {
  final JpegReconstructionData reconstructionData = state.reconstructionData;
  final int componentCount = scan.componentCount;
  final int segmentLength = 6 + 2 * componentCount;
  final Uint8List data = Uint8List(segmentLength + 2);
  int position = 0;
  data[position++] = 0xFF;
  data[position++] = JpegMarker.startOfScan;
  data[position++] = segmentLength >> 8;
  data[position++] = segmentLength & 0xFF;
  data[position++] = componentCount;
  for (int componentIndex = 0; componentIndex < componentCount; componentIndex++) {
    final JpegScanComponent scanComponent = scan.components[componentIndex];
    data[position++] = reconstructionData.components[scanComponent.componentIndex].identifier;
    data[position++] = (scanComponent.dcTableIndex << 4) + scanComponent.acTableIndex;
  }
  data[position++] = scan.spectralStart;
  data[position++] = scan.spectralEnd;
  data[position++] = (scan.successiveApproximationHigh << 4) | scan.successiveApproximationLow;
  output.add(data);
}

/// Writes the next group of Huffman-table definitions.
void _writeHuffmanTables(_JpegSerializationState state, BytesBuilder output) {
  final List<JpegHuffmanTable> definitions = state.reconstructionData.huffmanTables;
  int segmentLength = 2;
  for (int tableIndex = state.huffmanTableSegmentIndex; tableIndex < definitions.length; tableIndex++) {
    segmentLength += jpegHuffmanMaximumBitLength;
    for (final int symbolCount in definitions[tableIndex].counts) {
      segmentLength += symbolCount;
    }
    if (definitions[tableIndex].isLast) {
      break;
    }
  }
  final Uint8List data = Uint8List(segmentLength + 2);
  int position = 0;
  data[position++] = 0xFF;
  data[position++] = JpegMarker.defineHuffmanTable;
  data[position++] = segmentLength >> 8;
  data[position++] = segmentLength & 0xFF;
  while (true) {
    final int tableIndex = state.huffmanTableSegmentIndex++;
    if (tableIndex >= definitions.length) {
      throw const JpegXlInvalidBitstreamException(message: 'DHT index past end');
    }
    final JpegHuffmanTable definition = definitions[tableIndex];
    int index = definition.slotIdentifier;
    final JpegHuffmanCodeTable table;
    if (index & 0x10 != 0) {
      index -= 0x10;
      table = state.acHuffmanTables[index];
    } else {
      table = state.dcHuffmanTables[index];
    }
    table.populate(
      countsByBitLength: definition.counts,
      symbols: definition.values,
    );
    var totalCount = 0;
    var maxLength = 0;
    for (int codeLength = 0; codeLength < definition.counts.length; codeLength++) {
      if (definition.counts[codeLength] != 0) {
        maxLength = codeLength;
      }
      totalCount += definition.counts[codeLength];
    }
    totalCount--; // drop the synthetic 256 EOI symbol
    data[position++] = definition.slotIdentifier;
    for (int codeLength = 1; codeLength <= jpegHuffmanMaximumBitLength; codeLength++) {
      data[position++] = codeLength == maxLength ? definition.counts[codeLength] - 1 : definition.counts[codeLength];
    }
    for (int symbolIndex = 0; symbolIndex < totalCount; symbolIndex++) {
      data[position++] = definition.values[symbolIndex];
    }
    if (definition.isLast) {
      break;
    }
  }
  output.add(data);
}

/// Writes the next group of quantization-table definitions.
void _writeQuantizationTables(_JpegSerializationState state, BytesBuilder output) {
  final List<JpegQuantizationTable> tables = state.reconstructionData.quantizationTables;
  int segmentLength = 2;
  for (int tableIndex = state.quantizationTableSegmentIndex; tableIndex < tables.length; tableIndex++) {
    segmentLength += 1 + (tables[tableIndex].precision != 0 ? 2 : 1) * jpegDctBlockCoefficientCount;
    if (tables[tableIndex].isLast) {
      break;
    }
  }
  final Uint8List data = Uint8List(segmentLength + 2);
  int position = 0;
  data[position++] = 0xFF;
  data[position++] = JpegMarker.defineQuantizationTable;
  data[position++] = segmentLength >> 8;
  data[position++] = segmentLength & 0xFF;
  while (true) {
    final int tableIndex = state.quantizationTableSegmentIndex++;
    if (tableIndex >= tables.length) {
      throw const JpegXlInvalidBitstreamException(message: 'DQT index past end');
    }
    final JpegQuantizationTable table = tables[tableIndex];
    data[position++] = (table.precision << 4) + table.index;
    for (int coefficientIndex = 0; coefficientIndex < jpegDctBlockCoefficientCount; coefficientIndex++) {
      final int value = table.values[jpegZigZagToNaturalOrder[coefficientIndex]];
      if (table.precision != 0) {
        data[position++] = value >> 8;
      }
      data[position++] = value & 0xFF;
    }
    if (table.isLast) {
      break;
    }
  }
  output.add(data);
}

/// Entropy-encodes one baseline sequential 8 × 8 block.
/// [coefficients] contains natural-order quantized blocks and [baseOffset]
/// selects the first coefficient of the block to encode.
void _encodeBlockSequential(
  Int32List coefficients,
  int baseOffset,
  JpegHuffmanCodeTable dcHuffmanTable,
  JpegHuffmanCodeTable acHuffmanTable,
  int extraZeroRunCount,
  List<int> lastDcCoefficients,
  int componentIndex,
  _JpegBitWriter bitWriter,
) {
  final int dcCoefficient = coefficients[baseOffset];
  final int difference = dcCoefficient - lastDcCoefficients[componentIndex];
  lastDcCoefficients[componentIndex] = dcCoefficient;
  final int dcMagnitudeBitCount = jpegMagnitudeBitCount(difference);
  bitWriter.writeSymbol(dcMagnitudeBitCount, dcHuffmanTable);
  if (dcMagnitudeBitCount != 0) {
    bitWriter.writeBits(dcMagnitudeBitCount, jpegMagnitudeValue(difference, dcMagnitudeBitCount));
  }

  int zeroRunLength = 0;
  for (int coefficientIndex = 1; coefficientIndex < jpegDctBlockCoefficientCount; coefficientIndex++) {
    final int coefficient = coefficients[baseOffset + jpegZigZagToNaturalOrder[coefficientIndex]];
    if (coefficient == 0) {
      zeroRunLength++;
    } else {
      while (zeroRunLength > 15) {
        bitWriter.writeSymbol(0xF0, acHuffmanTable); // ZRL
        zeroRunLength -= 16;
      }
      final int bitCount = jpegMagnitudeBitCount(coefficient);
      final int symbol = (zeroRunLength << 4) + bitCount;
      bitWriter.writeSymbol(symbol, acHuffmanTable);
      bitWriter.writeBits(bitCount, jpegMagnitudeValue(coefficient, bitCount));
      zeroRunLength = 0;
    }
  }
  for (int runIndex = 0; runIndex < extraZeroRunCount; runIndex++) {
    bitWriter.writeSymbol(0xF0, acHuffmanTable);
    zeroRunLength -= 16;
  }
  if (zeroRunLength > 0) {
    bitWriter.writeSymbol(0, acHuffmanTable); // EOB
  }
}

/// Writes one scan header and its entropy-coded coefficient payload.
void _writeScan(_JpegSerializationState state, BytesBuilder output) {
  final JpegReconstructionData reconstructionData = state.reconstructionData;
  final JpegScan scan = reconstructionData.scans[state.scanIndex];
  if (state.isProgressive && !(scan.successiveApproximationHigh == 0 && scan.successiveApproximationLow == 0 && scan.spectralStart == 0 && scan.spectralEnd == 63)) {
    throw JpegXlUnsupportedException(feature: 'jpeg-progressive-scan');
  }
  _writeStartOfScan(scan, state, output);

  final _JpegBitWriter bitWriter = _JpegBitWriter(output: output);
  final int restartInterval = state.hasWrittenRestartInterval ? reconstructionData.restartInterval : 0;
  final List<int> lastDcCoefficients = List<int>.filled(4, 0);
  final bool isInterleaved = scan.componentCount > 1;

  final (int, int) minimumCodedUnitGrid = _calculateMinimumCodedUnitGrid(reconstructionData, scan);
  final int minimumCodedUnitsPerRow = minimumCodedUnitGrid.$1;
  final int minimumCodedUnitRows = minimumCodedUnitGrid.$2;

  int minimumCodedUnitsUntilRestart = restartInterval;
  int nextRestartMarker = 0;
  int blockScanIndex = 0;
  int extraZeroRunPosition = 0;
  int nextExtraZeroRunBlock = extraZeroRunPosition < scan.extraZeroRuns.length ? scan.extraZeroRuns[0].blockIndex : -1;
  int nextResetPointPosition = 0;
  int nextResetPoint = nextResetPointPosition < scan.resetPoints.length ? scan.resetPoints[nextResetPointPosition++] : -1;

  for (int unitY = 0; unitY < minimumCodedUnitRows; unitY++) {
    for (int unitX = 0; unitX < minimumCodedUnitsPerRow; unitX++) {
      if (restartInterval > 0 && minimumCodedUnitsUntilRestart == 0) {
        state.entropyPaddingBitPosition = bitWriter.padToByteBoundary(state.entropyPaddingBits, state.entropyPaddingBitPosition, reconstructionData.entropyPaddingBits.length);
        _emitMarker(output, JpegMarker.restart0 + nextRestartMarker);
        nextRestartMarker = (nextRestartMarker + 1) & 0x7;
        minimumCodedUnitsUntilRestart = restartInterval;
        for (int componentIndex = 0; componentIndex < lastDcCoefficients.length; componentIndex++) {
          lastDcCoefficients[componentIndex] = 0;
        }
      }
      for (int componentIndex = 0; componentIndex < scan.componentCount; componentIndex++) {
        final JpegScanComponent scanComponent = scan.components[componentIndex];
        final JpegComponent component = reconstructionData.components[scanComponent.componentIndex];
        final JpegHuffmanCodeTable dcHuffmanTable = state.dcHuffmanTables[scanComponent.dcTableIndex];
        final JpegHuffmanCodeTable acHuffmanTable = state.acHuffmanTables[scanComponent.acTableIndex];
        final int blockRowsPerUnit = isInterleaved ? component.verticalSamplingFactor : 1;
        final int blockColumnsPerUnit = isInterleaved ? component.horizontalSamplingFactor : 1;
        for (int blockRow = 0; blockRow < blockRowsPerUnit; blockRow++) {
          for (int blockColumn = 0; blockColumn < blockColumnsPerUnit; blockColumn++) {
            final int blockY = unitY * blockRowsPerUnit + blockRow;
            final int blockX = unitX * blockColumnsPerUnit + blockColumn;
            final int blockIndex = blockY * component.widthInBlocks + blockX;
            if (blockScanIndex == nextResetPoint) {
              nextResetPoint = nextResetPointPosition < scan.resetPoints.length ? scan.resetPoints[nextResetPointPosition++] : -1;
            }
            int extraZeroRunCount = 0;
            if (blockScanIndex == nextExtraZeroRunBlock) {
              extraZeroRunCount = scan.extraZeroRuns[extraZeroRunPosition].extraZeroRunCount;
              extraZeroRunPosition++;
              nextExtraZeroRunBlock = extraZeroRunPosition < scan.extraZeroRuns.length ? scan.extraZeroRuns[extraZeroRunPosition].blockIndex : -1;
            }
            _encodeBlockSequential(
              component.coefficients,
              blockIndex << 6,
              dcHuffmanTable,
              acHuffmanTable,
              extraZeroRunCount,
              lastDcCoefficients,
              scanComponent.componentIndex,
              bitWriter,
            );
            blockScanIndex++;
          }
        }
      }
      minimumCodedUnitsUntilRestart--;
    }
  }
  state.entropyPaddingBitPosition = bitWriter.padToByteBoundary(state.entropyPaddingBits, state.entropyPaddingBitPosition, reconstructionData.entropyPaddingBits.length);
  state.scanIndex++;
}

/// Appends a byte-aligned JPEG [marker] to [output].
void _emitMarker(BytesBuilder output, int marker) {
  // The bit writer flushes complete bytes eagerly and is byte-aligned here
  // (a restart is always preceded by padToByteBoundary), so appending the
  // marker directly to the output is correct.
  output.add(Uint8List.fromList([0xFF, marker]));
}

/// Returns the minimum-coded-unit grid required by [scan].
/// The record contains the unit count per row followed by the row count.
(int, int) _calculateMinimumCodedUnitGrid(JpegReconstructionData reconstructionData, JpegScan scan) {
  final bool isInterleaved = scan.componentCount > 1;
  final JpegComponent baseComponent = reconstructionData.components[scan.components[0].componentIndex];
  final int horizontalGroup = isInterleaved ? 1 : baseComponent.horizontalSamplingFactor;
  final int verticalGroup = isInterleaved ? 1 : baseComponent.verticalSamplingFactor;
  int maximumHorizontalSamplingFactor = 1;
  int maximumVerticalSamplingFactor = 1;
  for (final JpegComponent component in reconstructionData.components) {
    if (component.horizontalSamplingFactor > maximumHorizontalSamplingFactor) {
      maximumHorizontalSamplingFactor = component.horizontalSamplingFactor;
    }
    if (component.verticalSamplingFactor > maximumVerticalSamplingFactor) {
      maximumVerticalSamplingFactor = component.verticalSamplingFactor;
    }
  }
  final int unitsPerRow = _divideCeiling(reconstructionData.width * horizontalGroup, 8 * maximumHorizontalSamplingFactor);
  final int unitRows = _divideCeiling(reconstructionData.height * verticalGroup, 8 * maximumVerticalSamplingFactor);
  return (unitsPerRow, unitRows);
}

/// Divides [numerator] by [denominator], rounding toward positive infinity.
int _divideCeiling(int numerator, int denominator) => (numerator + denominator - 1) ~/ denominator;
