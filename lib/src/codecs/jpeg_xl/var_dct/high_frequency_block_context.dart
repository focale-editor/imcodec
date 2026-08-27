import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Maps high-frequency block properties to clustered entropy contexts.
final class HighFrequencyBlockContext {
  /// Mapping used to resolve cluster in the high-frequency block-context model.
  final Int32List clusterMap;

  /// Number of entropy clusters addressed by [clusterMap].
  final int clusterCount;

  /// Per-channel thresholds used to classify low-frequency coefficients.
  final List<Int32List> lowFrequencyThresholds;

  /// Thresholds used to classify quantization-field values.
  final Int32List quantizationFieldThresholds;

  /// Number of low-frequency contexts represented by the thresholds.
  final int lowFrequencyContextCount;

  /// The built-in default (a single `true` bit on the wire): a 39-entry
  /// cluster map, 15 clusters, no LF/QF thresholds. Public so the lossy
  /// encoder can compute context ids against the same default object the
  /// decoder uses without re-parsing a bitstream.
  factory HighFrequencyBlockContext.defaults() => HighFrequencyBlockContext._(
    clusterMap: Int32List.fromList(const [
      0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6, //
      7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14, //
      7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    ]),
    clusterCount: 15,
    lowFrequencyThresholds: [Int32List(0), Int32List(0), Int32List(0)],
    quantizationFieldThresholds: Int32List(0),
    lowFrequencyContextCount: 1,
  );

  /// Reads this structure from the bitstream.
  factory HighFrequencyBlockContext.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return HighFrequencyBlockContext.defaults();
    }
    final List<int> lowFrequencyThresholdCounts = List<int>.filled(3, 0);
    final List<Int32List> lowFrequencyThresholds = [];
    int lowFrequencyContextCount = 1;
    for (var i = 0; i < 3; i++) {
      lowFrequencyThresholdCounts[i] = reader.readBits(4);
      lowFrequencyContextCount *= lowFrequencyThresholdCounts[i] + 1;
      final Int32List thresholds = Int32List(lowFrequencyThresholdCounts[i]);
      for (var j = 0; j < lowFrequencyThresholdCounts[i]; j++) {
        thresholds[j] = unpackSigned(reader.readU32(0, 4, 16, 8, 272, 16, 65808, 32));
      }
      lowFrequencyThresholds.add(thresholds);
    }
    final int quantizationFieldThresholdCount = reader.readBits(4);
    final Int32List quantizationFieldThresholds = Int32List(quantizationFieldThresholdCount);
    // SPEC: the spec is missing the "1 +" here.
    for (var i = 0; i < quantizationFieldThresholdCount; i++) {
      quantizationFieldThresholds[i] = 1 + reader.readU32(0, 2, 4, 3, 12, 5, 44, 8);
    }
    int clusterMapSize = 39 * (quantizationFieldThresholdCount + 1);
    for (var i = 0; i < 3; i++) {
      clusterMapSize *= lowFrequencyThresholdCounts[i] + 1;
    }
    if (clusterMapSize > 39 * 64) {
      throw const JpegXlInvalidBitstreamException(message: 'High-frequency block context is too large');
    }
    final Int32List clusterMap = Int32List(clusterMapSize);
    final int clusterCount = EntropyStream.readClusterMap(reader, clusterMap, 16);
    return HighFrequencyBlockContext._(
      clusterMap: clusterMap,
      clusterCount: clusterCount,
      lowFrequencyThresholds: lowFrequencyThresholds,
      quantizationFieldThresholds: quantizationFieldThresholds,
      lowFrequencyContextCount: lowFrequencyContextCount,
    );
  }

  /// Creates a validated high-frequency block-context model.
  HighFrequencyBlockContext._({
    required this.clusterMap,
    required this.clusterCount,
    required this.lowFrequencyThresholds,
    required this.quantizationFieldThresholds,
    required this.lowFrequencyContextCount,
  });
}
