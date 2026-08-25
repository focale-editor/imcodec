import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// The HF block context model: cluster map over (channel, orderID,
/// qf-threshold bucket, lf-threshold bucket).
final class HfBlockContext {
  /// Stores the cluster map value used while processing JPEG XL data.
  ///
  final Int32List clusterMap;

  /// Stores the num clusters value used while processing JPEG XL data.
  ///
  final int numClusters;

  /// Stores the lf thresholds value used while processing JPEG XL data.
  ///
  final List<Int32List> lfThresholds;

  /// Stores the qf thresholds value used while processing JPEG XL data.
  ///
  final Int32List qfThresholds;

  /// Stores the num lFContexts value used while processing JPEG XL data.
  ///
  final int numLFContexts;

  /// The built-in default (a single `true` bit on the wire): a 39-entry
  /// cluster map, 15 clusters, no LF/QF thresholds. Public so the lossy
  /// encoder can compute context ids against the same default object the
  /// decoder uses without re-parsing a bitstream.
  factory HfBlockContext.defaults() => HfBlockContext._(
    clusterMap: Int32List.fromList(const [
      0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6, //
      7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14, //
      7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
    ]),
    numClusters: 15,
    lfThresholds: [Int32List(0), Int32List(0), Int32List(0)],
    qfThresholds: Int32List(0),
    numLFContexts: 1,
  );

  /// Processes read information in a JPEG XL codestream.
  ///
  factory HfBlockContext.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return HfBlockContext.defaults();
    }
    final nbLFThresh = List<int>.filled(3, 0);
    final lfThresholds = <Int32List>[];
    var lfCtx = 1;
    for (var i = 0; i < 3; i++) {
      nbLFThresh[i] = reader.readBits(4);
      lfCtx *= nbLFThresh[i] + 1;
      final t = Int32List(nbLFThresh[i]);
      for (var j = 0; j < nbLFThresh[i]; j++) {
        t[j] = unpackSigned(reader.readU32(0, 4, 16, 8, 272, 16, 65808, 32));
      }
      lfThresholds.add(t);
    }
    final int nbQfThresh = reader.readBits(4);
    final qfThresholds = Int32List(nbQfThresh);
    // SPEC: the spec is missing the "1 +" here.
    for (var i = 0; i < nbQfThresh; i++) {
      qfThresholds[i] = 1 + reader.readU32(0, 2, 4, 3, 12, 5, 44, 8);
    }
    int bSize = 39 * (nbQfThresh + 1);
    for (var i = 0; i < 3; i++) {
      bSize *= nbLFThresh[i] + 1;
    }
    if (bSize > 39 * 64) {
      throw const JpegXlInvalidBitstreamException(message: 'HF block size too large');
    }
    final clusterMap = Int32List(bSize);
    final int numClusters = EntropyStream.readClusterMap(reader, clusterMap, 16);
    return HfBlockContext._(clusterMap: clusterMap, numClusters: numClusters, lfThresholds: lfThresholds, qfThresholds: qfThresholds, numLFContexts: lfCtx);
  }

  /// Creates Hf block context state for JPEG XL processing.
  ///
  HfBlockContext._({
    required this.clusterMap,
    required this.numClusters,
    required this.lfThresholds,
    required this.qfThresholds,
    required this.numLFContexts,
  });
}
