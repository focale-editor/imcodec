import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_table_of_contents.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Caches natural coefficient orders as packed row-and-column values.
final List<Int32List?> _naturalOrderCache = List.filled(13, null);

/// Returns the natural coefficient scan order for [orderIdentifier].
/// The lossy encoder uses the same cached order as the decoder.
Int32List getNaturalOrder(int orderIdentifier) {
  final Int32List? cached = _naturalOrderCache[orderIdentifier];
  if (cached != null) {
    return cached;
  }
  final TransformType transformType = TransformType.byOrderIdentifier(orderIdentifier);
  final int coefficientCount = transformType.pixelHeight * transformType.pixelWidth;
  final List<int> coordinates = List<int>.generate(coefficientCount, (index) {
    final int row = index ~/ transformType.pixelWidth;
    final int column = index % transformType.pixelWidth;
    return (row << 16) | column;
  });
  final int maximumDimension = transformType.dctSelectHeight > transformType.dctSelectWidth ? transformType.dctSelectHeight : transformType.dctSelectWidth;
  coordinates.sort((first, second) {
    final int firstRow = first >> 16;
    final int firstColumn = first & 0xFFFF;
    final int secondRow = second >> 16;
    final int secondColumn = second & 0xFFFF;
    final bool firstIsLowestFrequency = firstRow < transformType.dctSelectHeight && firstColumn < transformType.dctSelectWidth;
    final bool secondIsLowestFrequency = secondRow < transformType.dctSelectHeight && secondColumn < transformType.dctSelectWidth;
    if (firstIsLowestFrequency && !secondIsLowestFrequency) {
      return -1;
    }
    if (secondIsLowestFrequency && !firstIsLowestFrequency) {
      return 1;
    }
    if (firstIsLowestFrequency && secondIsLowestFrequency) {
      if (secondRow != firstRow) {
        return firstRow - secondRow;
      }
      return firstColumn - secondColumn;
    }
    final int firstScaledRow = firstRow * maximumDimension ~/ transformType.dctSelectHeight;
    final int firstScaledColumn = firstColumn * maximumDimension ~/ transformType.dctSelectWidth;
    final int secondScaledRow = secondRow * maximumDimension ~/ transformType.dctSelectHeight;
    final int secondScaledColumn = secondColumn * maximumDimension ~/ transformType.dctSelectWidth;
    final int firstDiagonal = firstScaledRow + firstScaledColumn;
    final int secondDiagonal = secondScaledRow + secondScaledColumn;
    if (firstDiagonal != secondDiagonal) {
      return firstDiagonal - secondDiagonal;
    }
    int firstPositionWithinDiagonal = firstScaledColumn - firstScaledRow;
    int secondPositionWithinDiagonal = secondScaledColumn - secondScaledRow;
    if (firstDiagonal & 1 == 1) {
      firstPositionWithinDiagonal = -firstPositionWithinDiagonal;
    }
    if (secondDiagonal & 1 == 1) {
      secondPositionWithinDiagonal = -secondPositionWithinDiagonal;
    }
    return firstPositionWithinDiagonal - secondPositionWithinDiagonal;
  });
  return _naturalOrderCache[orderIdentifier] = Int32List.fromList(coordinates);
}

/// Holds coefficient orders and the shared entropy stream for one VarDCT pass.
final class HighFrequencyPass {
  /// Bit set identifying each transform order explicitly carried by the pass.
  late final int usedOrders;

  /// Per-channel coefficient orders indexed by transform order identifier.
  final List<List<Int32List>?> _order = List.filled(13, null);

  /// Entropy stream used to decode coefficient-order permutations.
  late final EntropyStream contextStream;

  /// Reads coefficient orders for one progressive VarDCT pass.
  HighFrequencyPass({
    required BitReader reader,
    required Frame frame,
    required int passIndex,
  }) {
    usedOrders = reader.readU32(0x5F, 0, 0x13, 0, 0, 0, 0, 13);
    final EntropyStream? stream = usedOrders != 0 ? EntropyStream.read(reader: reader, distributionCount: 8) : null;
    // Permuted orders must be read from the bitstream now; natural orders
    // for unused IDs are built lazily on first use (the big zigzag sorts
    // are expensive and most images touch only a few transform types).
    for (var b = 0; b < 13; b++) {
      if (usedOrders & (1 << b) == 0) {
        continue;
      }
      final Int32List naturalOrder = getNaturalOrder(b);
      final int len = naturalOrder.length;
      _order[b] = List.generate(3, (c) {
        final List<int> perm = readPermutation(reader, stream!, len, len ~/ 64);
        final o = Int32List(len);
        for (var i = 0; i < len; i++) {
          o[i] = naturalOrder[perm[i]];
        }
        return o;
      }, growable: false);
    }
    if (stream != null && !stream.validateFinalState()) {
      throw JpegXlInvalidBitstreamException(message: 'ANS state decoding HFPass perms: $passIndex');
    }
    final int contextCount = 495 * frame.highFrequencyGlobal!.highFrequencyPresetCount * frame.lowFrequencyGlobal.highFrequencyBlockContext!.clusterCount;
    contextStream = EntropyStream.read(reader: reader, distributionCount: contextCount);
  }

  /// orderFor(orderIdentifier)[channel] -> packed (y << 16 | x) coefficient
  /// positions.
  List<Int32List> orderFor(int orderIdentifier) {
    final List<Int32List>? cached = _order[orderIdentifier];
    if (cached != null) {
      return cached;
    }
    final Int32List naturalOrder = getNaturalOrder(orderIdentifier);
    return _order[orderIdentifier] = List.filled(3, naturalOrder, growable: false);
  }
}
