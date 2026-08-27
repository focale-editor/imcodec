import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/low_frequency_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Holds transform, quantization, correlation, and filter metadata for one low-frequency group.
final class HighFrequencyMetadata {
  /// Number of transform blocks described by the group.
  late final int blockCount;

  /// Block width in samples.
  late final int blockWidth;

  /// Transform type occupying each position in the block grid.
  late final Int32List _transformSelectionIndices;

  /// Quantization multiplier for each position in the block grid.
  late final Int32List highFrequencyMultiplier;

  /// Decoded correlation, block-information, and sharpness channels.
  /// The four entries contain X-from-Y, B-from-Y, the two-row block table,
  /// and sharpness respectively.
  late final List<ModularChannel> highFrequencyStreamChannels;

  /// Vertical grid position of each transform block.
  late final Int32List blockRows;

  /// Horizontal grid position of each transform block.
  late final Int32List blockColumns;

  /// Cached transform-block indices partitioned by pass group.
  List<Int32List>? _blockIndicesByGroup;

  /// Decodes the high-frequency metadata for [parent].
  HighFrequencyMetadata({
    required BitReader reader,
    required LowFrequencyGroup parent,
    required Frame frame,
  }) {
    final int blockHeight = parent.blockHeight;
    final int decodedBlockWidth = parent.blockWidth;
    final int positionBitCount = ceilLog2(blockHeight * decodedBlockWidth);
    blockCount = 1 + reader.readBits(positionBitCount);
    final int correlationHeight = (blockHeight + 7) ~/ 8;
    final int correlationWidth = (decodedBlockWidth + 7) ~/ 8;
    final ModularChannel xFromY = ModularChannel(height: correlationHeight, width: correlationWidth, verticalShift: 0, horizontalShift: 0);
    final ModularChannel bFromY = ModularChannel(height: correlationHeight, width: correlationWidth, verticalShift: 0, horizontalShift: 0);
    final ModularChannel blockInformation = ModularChannel(height: 2, width: blockCount, verticalShift: 0, horizontalShift: 0);
    final ModularChannel sharpness = ModularChannel(height: blockHeight, width: decodedBlockWidth, verticalShift: 0, horizontalShift: 0);
    final ModularStream highFrequencyStream = ModularStream.read(
      reader: reader,
      context: frame.modularContext,
      streamIndex: 1 + 2 * frame.lowFrequencyGroupCount + parent.lowFrequencyGroupId,
      channelArray: [xFromY, bFromY, blockInformation, sharpness],
    );
    highFrequencyStream.decodeChannels(reader);
    highFrequencyStreamChannels = [for (var i = 0; i < 4; i++) highFrequencyStream.getChannel(i)];

    blockWidth = decodedBlockWidth;
    _transformSelectionIndices = Int32List(blockHeight * decodedBlockWidth)..fillRange(0, blockHeight * decodedBlockWidth, -1);
    highFrequencyMultiplier = Int32List(blockHeight * decodedBlockWidth);
    blockRows = Int32List(blockCount);
    blockColumns = Int32List(blockCount);
    final Int32List blockInformationBuffer = highFrequencyStreamChannels[2].buffer!;
    int lastRow = 0;
    int lastColumn = 0;
    for (var i = 0; i < blockCount; i++) {
      final int type = blockInformationBuffer[i]; // row 0: type
      if (type > 26 || type < 0) {
        throw JpegXlInvalidBitstreamException(message: 'invalid transform type: $type');
      }
      final TransformType transformType = TransformType.values[type];
      final int multiplier = 1 + blockInformationBuffer[blockCount + i]; // row 1: multiplier - 1
      final int packedPosition = _placeBlock(
        blockHeight: blockHeight,
        blockWidth: decodedBlockWidth,
        startRow: lastRow,
        startColumn: lastColumn,
        transformType: transformType,
        multiplier: multiplier,
      );
      lastRow = packedPosition >> 20;
      lastColumn = packedPosition & 0xFFFFF;
      blockRows[i] = lastRow;
      blockColumns[i] = lastColumn;
    }
  }

  /// Returns the transform type covering grid position ([y], [x]).
  TransformType? transformTypeAt(int y, int x) {
    final int transformIndex = _transformSelectionIndices[y * blockWidth + x];
    return transformIndex < 0 ? null : TransformType.values[transformIndex];
  }

  /// Returns the quantization multiplier at grid position ([y], [x]).
  int highFrequencyMultiplierAt(int y, int x) => highFrequencyMultiplier[y * blockWidth + x];

  /// Returns the sharpness value at grid position ([y], [x]).
  int sharpnessAt(int y, int x) => highFrequencyStreamChannels[3].buffer![y * blockWidth + x];

  /// [blockCount] block indices partitioned by the (group-dim-sized) pass-group
  /// they fall into, keyed by `(blockRows[i] >> 5) * 8 + (blockColumns[i] >> 5)` — an
  /// LF group always spans exactly 8x8 groups (`Frame.groupPositionInLowFrequencyGroup`'s
  /// `pos.y`/`pos.x` range), so this fixed 64-bucket layout mirrors the same
  /// group-grid assumption `HighFrequencyCoefficients` already hardcodes via `<< 5`/
  /// `32`. Computed once per LF group and shared by every pass and every
  /// pass-group that reads it, instead of each one separately re-scanning
  /// all [blockCount] entries to find its own subset.
  List<Int32List> blockIndicesByGroup() {
    final List<Int32List>? cached = _blockIndicesByGroup;
    if (cached != null) {
      return cached;
    }
    final Int32List counts = Int32List(64);
    for (var i = 0; i < blockCount; i++) {
      counts[(blockRows[i] >> 5) * 8 + (blockColumns[i] >> 5)]++;
    }
    final List<Int32List> buckets = List<Int32List>.generate(64, (index) => Int32List(counts[index]));
    final Int32List fillPositions = Int32List(64);
    for (var i = 0; i < blockCount; i++) {
      final int key = (blockRows[i] >> 5) * 8 + (blockColumns[i] >> 5);
      buckets[key][fillPositions[key]++] = i;
    }
    return _blockIndicesByGroup = buckets;
  }

  /// Places [transformType] at the first free grid position in raster order.
  /// The returned integer packs the row in its high bits and the column in
  /// its low 20 bits.
  int _placeBlock({
    required int blockHeight,
    required int blockWidth,
    required int startRow,
    required int startColumn,
    required TransformType transformType,
    required int multiplier,
  }) {
    int x = startColumn;
    for (var y = startRow; y < blockHeight; y++, x = 0) {
      final int rowBase = y * blockWidth;
      outerX:
      for (; x < blockWidth; x++) {
        if (transformType.dctSelectWidth + x > blockWidth) {
          break; // next row
        }
        // Check the space is free.
        for (var ix = 0; ix < transformType.dctSelectWidth; ix++) {
          final int transformIndex = _transformSelectionIndices[rowBase + x + ix];
          if (transformIndex >= 0) {
            x += TransformType.values[transformIndex].dctSelectWidth - 1;
            continue outerX;
          }
        }
        if (transformType.dctSelectHeight + y > blockHeight) {
          throw const JpegXlInvalidBitstreamException(message: 'block does not fit vertically');
        }
        for (var iy = 0; iy < transformType.dctSelectHeight; iy++) {
          final int base = (y + iy) * blockWidth + x;
          _transformSelectionIndices.fillRange(base, base + transformType.dctSelectWidth, transformType.type);
          highFrequencyMultiplier.fillRange(base, base + transformType.dctSelectWidth, multiplier);
        }
        return (y << 20) | x;
      }
    }
    throw const JpegXlInvalidBitstreamException(message: 'could not place block');
  }
}
