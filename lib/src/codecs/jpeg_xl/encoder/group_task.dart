import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/encoder/context_tree.dart';

/// One group's share of a modular residual pass.
///
/// A job carries copies of the tiles it needs rather than references into the
/// whole image, so it can be handed to another isolate unchanged. Groups never
/// read each other's data, which is what lets a caller run them in parallel.
final class ModularResidualJob {
  /// Tile of every plane, in plane order.
  final List<Int32List> tiles;

  /// Tile width in samples.
  final int tileWidth;

  /// Tile height in samples.
  final int tileHeight;

  /// Row stride of each source plane.
  final int sourceWidth;

  /// Horizontal origin of the tile in each source plane.
  final int sourceX;

  /// Vertical origin of the tile in each source plane.
  final int sourceY;

  /// Whether the self-correcting weighted predictor is used.
  final bool useWeightedPredictor;

  /// Tree property identifiers collected for training.
  final List<int> properties;

  /// Distance between two training samples.
  final int stride;

  /// Training-sample counter this group starts from.
  final int strideCounter;

  /// Whether the tree may condition on the channel index and prior channel.
  final bool crossChannel;

  /// Creates a residual job for one group.
  const ModularResidualJob({
    required this.tiles,
    required this.tileWidth,
    required this.tileHeight,
    required this.sourceWidth,
    required this.sourceX,
    required this.sourceY,
    required this.useWeightedPredictor,
    required this.properties,
    required this.stride,
    required this.strideCounter,
    required this.crossChannel,
  });
}

/// Residuals and training samples produced by one [ModularResidualJob].
final class ModularResidualResult {
  /// Packed-signed residuals for every sample of the group.
  final Int32List values;

  /// Weighted-predictor maximum errors, or `null` for the gradient predictor.
  final Int32List? maximumErrors;

  /// Property vectors of the group's training samples.
  final Int32List trainingProperties;

  /// Hybrid-integer tokens of the group's training samples.
  final Int32List trainingTokens;

  /// Fast-path token counts for each source plane, or `null` when uncollected.
  final List<Int32List>? tokenCounts;

  /// Fast-path hybrid payload bits for each source plane.
  final Int32List? extraBitCounts;

  /// Creates a residual result.
  const ModularResidualResult({
    required this.values,
    required this.maximumErrors,
    required this.trainingProperties,
    required this.trainingTokens,
    required this.tokenCounts,
    required this.extraBitCounts,
  });
}

/// The training set of one predictor, ready for context-tree learning.
///
/// Learning is per predictor rather than per group, so it forms its own small
/// batch of independent jobs that a runner can spread the same way.
final class ModularTreeJob {
  /// Property vectors of every training sample, laid out flat.
  final Int32List trainingProperties;

  /// Hybrid-integer token of every training sample.
  final Int32List trainingTokens;

  /// Tree property identifiers, in index order.
  final List<int> properties;

  /// Fixed channel count, or zero when the tree must be learned.
  final int fixedChannelCount;

  /// Creates a tree-learning job.
  const ModularTreeJob({
    required this.trainingProperties,
    required this.trainingTokens,
    required this.properties,
    this.fixedChannelCount = 0,
  });
}

/// One group's share of a modular context pass.
final class ModularContextJob {
  /// Tile of every plane, in plane order.
  final List<Int32List> tiles;

  /// Tile width in samples.
  final int tileWidth;

  /// Tile height in samples.
  final int tileHeight;

  /// Tree every sample is classified against.
  final ContextTree tree;

  /// Weighted-predictor maximum errors from the matching residual pass.
  final Int32List? maximumErrors;

  /// Whether the tree may condition on the channel index and prior channel.
  final bool crossChannel;

  /// Number of contexts the result must contain.
  final int sampleCount;

  /// Context assigned without inspecting pixels, or `null` for tree lookup.
  final int? constantContext;

  /// Samples assigned to each successive channel context, when fixed.
  final int? samplesPerChannel;

  /// Creates a context job for one group.
  const ModularContextJob({
    required this.tiles,
    required this.tileWidth,
    required this.tileHeight,
    required this.tree,
    required this.maximumErrors,
    required this.crossChannel,
    required this.sampleCount,
    this.constantContext,
    this.samplesPerChannel,
  });
}
