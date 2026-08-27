import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/encoder/entropy_encoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_writer.dart';

/// Learns a per-image meta-adaptive context tree, the biggest lever for
/// lossless modular size after prediction: richer contexts condition the
/// residual histograms far better than a fixed handful.
/// The tree tests decoder property values (`_property` cases) against
/// thresholds; leaves are contexts. The predictor is chosen by the caller;
/// property 15 (the weighted predictor's max-error) is only meaningful when
/// the leaves use predictor 6, so the property set is predictor-dependent.

/// Property set for the clamped-gradient predictor (mirrors `_property`):
/// 4 = |N|, 5 = |W|, 6 = N, 7 = W, 8 = W's own gradient-prediction error,
/// 9 = the gradient prediction W+N-NW, 10 = W-NW, 11 = NW-N, 12 = N-NE,
/// 13 = N-NN, 14 = W-WW. Properties 8 and 9 (error-feedback and
/// predicted-value) are what libjxl's modular encoder leans on; the decoder
/// already computes them (`_property` cases 8/9) — they were simply never in
/// this encoder's learned-tree property set.
const gradProperties = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];

/// Property set for the weighted predictor: the gradient set plus 15
/// (max-error), which is where WP's advantage lives.
const wpProperties = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

/// Property sets for multi-channel RCT colour: the base sets plus channel
/// index (0) and the immediate prior channel's cross-channel properties
/// (16 = |value|, 17 = value, 18 = |gradient residual|, 19 = gradient
/// residual — the decoder's `_property` cases 16-19 for the nearest prior
/// same-size channel). Property 0 lets the tree specialise per channel
/// (Y/Co/Cg) instead of sharing one tree; 16-19 let Co/Cg condition on the
/// prior channel. Used only on the RCT path (three equal-size channels, no
/// meta channel, so channel index == plane index) — see `computeProps`'s
/// `channelIndex`/`prior` args and the encoder's callers.
const rctGradProperties = [
  4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0, 16, 17, 18, 19, //
];

/// Specification constant used for reversible color transform weighted-predictor properties.
const rctWpProperties = [
  4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 16, 17, 18, 19, //
];

/// Candidate split thresholds (the decoder walk is `property > value`).
const _thresholds = [
  -64, -32, -16, -8, -4, -2, -1, 0, 1, 2, 4, 8, 16, 32, 64, 128, //
];

/// Computes [properties] for pixel (y, x) of a tile into [out] (same length),
/// mirroring the decoder's `_property`. Property 15 (WP max-error) is not
/// derivable from the tile, so its value is supplied as [maxError].
/// [channelIndex] supplies property 0 (the decoder's channel index). When
/// [prior] (the immediate prior same-size channel's tile, same [tw]/[th]) is
/// given and [channelIndex] >= 1, properties 16-19 are the decoder's
/// cross-channel values for that prior channel at (y, x): 16 = |value|,
/// 17 = value, 18 = |gradient residual|, 19 = gradient residual. Grayscale /
/// palette / the first RCT channel pass no prior, so those props stay 0 —
/// exactly what the decoder returns there (`k - 16 >= 4 * channelIndex`).
void computeProps(Int32List tile, int tw, int th, int y, int x, List<int> properties, int maxError, Int32List out, {int channelIndex = 0, Int32List? prior}) {
  final int o = y * tw + x;
  final int n = y > 0
      ? tile[o - tw]
      : x > 0
      ? tile[o - 1]
      : 0;
  final int w = x > 0
      ? tile[o - 1]
      : y > 0
      ? tile[o - tw]
      : 0;
  final int nw = x > 0 ? (y > 0 ? tile[o - tw - 1] : tile[o - 1]) : (y > 0 ? tile[o - tw] : 0);
  final int ne = x + 1 < tw && y > 0 ? tile[o - tw + 1] : n;
  final int nn = y > 1 ? tile[o - 2 * tw] : n;
  final int ww = x > 1 ? tile[o - 2] : w;
  // Property 9: the clamped-gradient prediction value W+N-NW.
  // Property 8: W minus its *own* gradient prediction — the prediction error
  // at the west neighbour. Both mirror the decoder's `_property` cases 9/8
  // (including their signed-32 truncation) exactly, so a tree that splits on
  // them decodes identically. Case 8 reads the W pixel's neighbours (its W,
  // N, NW), with the decoder's edge handling at x==1/y==0.
  final int grad9 = (w + n - nw).toSigned(32);
  final int err8;
  if (x <= 0) {
    err8 = w; // decoder returns _west(o) here
  } else {
    final int westW = x > 1 ? tile[o - 2] : (y > 0 ? tile[o - tw - 1] : 0);
    final int northW = y > 0 ? tile[o - tw - 1] : (x > 1 ? tile[o - 2] : 0);
    final int nwW = x > 1 ? (y > 0 ? tile[o - tw - 2] : tile[o - 2]) : (y > 0 ? tile[o - tw - 1] : 0);
    err8 = (w - (westW + northW - nwW).toSigned(32)).toSigned(32);
  }
  // Cross-channel (16-19): the immediate prior channel's value and its own
  // clamped-gradient residual at (y, x). Mirrors the decoder's `_property`
  // cases 16-19 (including `_clamp3` and signed-32 truncation, and the
  // rW=0-at-left-edge / rN=rW-at-top-edge / rNW=rW edge handling) for the
  // nearest prior same-size channel. Only the first prior is exposed here
  // (props 16-19); the decoder's further-back channels (20+) aren't used.
  var cx16 = 0;
  var cx17 = 0;
  var cx18 = 0;
  var cx19 = 0;
  if (channelIndex >= 1 && prior != null) {
    final int rC = prior[o];
    final int rW = x > 0 ? prior[o - 1] : 0;
    final int rN = y > 0 ? prior[o - tw] : rW;
    final int rNW = x > 0 && y > 0 ? prior[o - tw - 1] : rW;
    final lo = rW < rN ? rW : rN;
    final hi = rW < rN ? rN : rW;
    final int g = (rW + rN - rNW).toSigned(32);
    final pred = g < lo ? lo : (g > hi ? hi : g);
    final int rG = (rC - pred).toSigned(32);
    cx16 = rC.abs();
    cx17 = rC;
    cx18 = rG.abs();
    cx19 = rG;
  }
  for (var i = 0; i < properties.length; i++) {
    out[i] = switch (properties[i]) {
      0 => channelIndex,
      4 => n.abs(),
      5 => w.abs(),
      6 => n,
      7 => w,
      8 => err8,
      9 => grad9,
      10 => w - nw,
      11 => nw - n,
      12 => n - ne,
      13 => n - nn,
      14 => w - ww,
      15 => maxError,
      16 => cx16,
      17 => cx17,
      18 => cx18,
      19 => cx19,
      _ => 0,
    };
  }
}

/// Returns the base-two logarithm of [value].
double _binaryLogarithm(double value) => math.log(value) * 1.4426950408889634;

/// Stores one learned split or leaf in a modular context tree.
final class _ContextTreeNode {
  /// Index into the serialized tree properties, or `-1` for a leaf.
  int propertyIndex = -1; // index into treeProperties; < 0 => leaf
  /// Predictor value assigned to a leaf.
  int value = 0;

  /// Entropy context assigned after the tree has been ordered.
  int context = -1;

  /// Child selected when the split comparison succeeds.
  _ContextTreeNode? left;

  /// Child selected when the split comparison fails.
  _ContextTreeNode? right;

  /// Training-sample indices that currently reach this node.
  List<int> samples; // sample indices (training)
  /// Candidate property index, with negative values denoting unresolved states.
  int splitProperty = -2; // -2 = not computed, -1 = no useful split
  /// Threshold used to partition [samples].
  int splitThreshold = 0;

  /// Estimated entropy reduction produced by the selected split.
  double informationGain = 0;

  /// Creates an unresolved node for the supplied training samples.
  _ContextTreeNode({
    required this.samples,
  });
}

/// A learned tree ready to serialize and to assign contexts with.
final class ContextTree {
  /// Root of the learned decision tree.
  final _ContextTreeNode _root;

  /// Number of entropy contexts.
  final int contextCount;

  /// Nodes in breadth-first serialization order.
  final List<_ContextTreeNode> _orderedNodes; // BFS order for serialization

  /// The decoder property ids this tree splits on (index order).
  final List<int> properties;

  /// Total zeroth-order entropy (bits) this tree's leaves achieve on the
  /// strided training set — the sum over leaves of each leaf's token-histogram
  /// entropy. A predictor-independent, context-modelled cost signal available
  /// the moment the tree is learned (before Pass B / entropy coding); used to
  /// compare the gradient vs weighted-predictor pipelines cheaply.
  final double trainingBits;

  /// Creates a learned tree from its finalized nodes and cost.
  ContextTree._({
    required this._root,
    required this.contextCount,
    required this._orderedNodes,
    required this.properties,
    required this.trainingBits,
  });

  /// Number of distinct contexts (tree leaves).
  int get contexts => contextCount;
}

/// Computes the zero-order entropy of [counts] containing [total] samples.
double _countsEntropy(List<int> counts, int total) {
  if (total == 0) {
    return 0;
  }
  var bits = 0.0;
  final double lt = total.toDouble();
  for (final c in counts) {
    if (c > 0) {
      bits += c * _binaryLogarithm(lt / c);
    }
  }
  return bits;
}

/// Learns a tree from (properties, token) training samples. [props] is
/// flat: sample s uses props[s*P .. s*P+P). Splits stop at [maxContexts]
/// leaves or when a split saves fewer than [minGainBits] bits.
ContextTree learnContextTree(Int32List props, Int32List tokens, List<int> properties, {int maxContexts = 64, double minGainBits = 96}) {
  final int p = properties.length;
  final int n = tokens.length;
  var maxToken = 0;
  for (final t in tokens) {
    if (t > maxToken) {
      maxToken = t;
    }
  }
  final int alpha = maxToken + 1;
  final int nb = _thresholds.length; // bins = thresholds + 1

  int binOf(int v) {
    var lo = 0;
    var hi = nb;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (v > _thresholds[mid]) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo; // in [0, nb]
  }

  void computeSplit(_ContextTreeNode node) {
    node.splitProperty = -1;
    if (node.samples.length < 1024) {
      return;
    }
    final parent = List<int>.filled(alpha, 0);
    for (final int s in node.samples) {
      parent[tokens[s]]++;
    }
    final int total = node.samples.length;
    final double parentBits = _countsEntropy(parent, total);
    for (var pi = 0; pi < p; pi++) {
      final binHist = List<List<int>>.generate(nb + 1, (_) => List<int>.filled(alpha, 0), growable: false);
      final binTotal = List<int>.filled(nb + 1, 0);
      for (final int s in node.samples) {
        final int b = binOf(props[s * p + pi]);
        binHist[b][tokens[s]]++;
        binTotal[b]++;
      }
      final right = List<int>.filled(alpha, 0);
      var rightTotal = 0;
      for (var i = 0; i < nb; i++) {
        for (var t = 0; t < alpha; t++) {
          right[t] += binHist[i][t];
        }
        rightTotal += binTotal[i];
        final int leftTotal = total - rightTotal;
        if (rightTotal == 0 || leftTotal == 0) {
          continue;
        }
        var leftBits = 0.0;
        final double llt = leftTotal.toDouble();
        for (var t = 0; t < alpha; t++) {
          final int lc = parent[t] - right[t];
          if (lc > 0) {
            leftBits += lc * _binaryLogarithm(llt / lc);
          }
        }
        final double rightBits = _countsEntropy(right, rightTotal);
        final double gain = parentBits - leftBits - rightBits;
        if (gain > node.informationGain) {
          node.informationGain = gain;
          node.splitProperty = pi;
          node.splitThreshold = _thresholds[i];
        }
      }
    }
    if (node.informationGain < minGainBits) {
      node.splitProperty = -1;
    }
  }

  final root = _ContextTreeNode(samples: [for (var i = 0; i < n; i++) i]);
  computeSplit(root);
  var leaves = 1;
  final frontier = <_ContextTreeNode>[root];
  while (leaves < maxContexts) {
    _ContextTreeNode? pick;
    var pickGain = 0.0;
    for (final node in frontier) {
      if (node.splitProperty >= 0 && node.informationGain > pickGain) {
        pickGain = node.informationGain;
        pick = node;
      }
    }
    if (pick == null) {
      break;
    }
    final int pi = pick.splitProperty;
    final int thr = pick.splitThreshold;
    final leftS = <int>[];
    final rightS = <int>[];
    for (final int s in pick.samples) {
      if (props[s * p + pi] > thr) {
        leftS.add(s);
      } else {
        rightS.add(s);
      }
    }
    pick
      ..propertyIndex = pi
      ..value = thr
      ..left = _ContextTreeNode(samples: leftS)
      ..right = _ContextTreeNode(samples: rightS)
      ..samples = const []
      ..splitProperty = -1;
    computeSplit(pick.left!);
    computeSplit(pick.right!);
    frontier
      ..remove(pick)
      ..add(pick.left!)
      ..add(pick.right!);
    leaves++;
  }

  // Training entropy: sum of each leaf's token-histogram entropy. `frontier`
  // holds exactly the leaves (split nodes were removed as they split).
  var trainingBits = 0.0;
  final leafHist = List<int>.filled(alpha, 0);
  for (final leaf in frontier) {
    for (final int s in leaf.samples) {
      leafHist[tokens[s]]++;
    }
    trainingBits += _countsEntropy(leafHist, leaf.samples.length);
    for (final int s in leaf.samples) {
      leafHist[tokens[s]] = 0;
    }
  }

  final ordered = <_ContextTreeNode>[];
  var nextContext = 0;
  final queue = <_ContextTreeNode>[root];
  while (queue.isNotEmpty) {
    final _ContextTreeNode node = queue.removeAt(0);
    ordered.add(node);
    if (node.propertyIndex < 0) {
      node.context = nextContext++;
    } else {
      queue.add(node.left!);
      queue.add(node.right!);
    }
  }
  return ContextTree._(root: root, contextCount: nextContext, orderedNodes: ordered, properties: properties, trainingBits: trainingBits);
}

/// Serializes the tree in the decoder's MA-tree format: a 6-context entropy
/// stream carrying, per node in BFS order, (property+1, value) for inner
/// nodes and (0, predictor, offset, mulLog, mulBits) for leaves. [predictor]
/// is the decoder predictor id a leaf uses (5 = clamped gradient,
/// 6 = self-correcting weighted) unless [leafPredictors] is given, in which
/// case each leaf uses `leafPredictors[leaf.context]` (per-leaf predictor
/// selection). The decoder reads a predictor per leaf and maintains WP state
/// for every pixel whenever any leaf is WP, so gradient and WP leaves may
/// coexist in one tree.
void serializeContextTree(BitWriter w, ContextTree tree, int predictor, [List<int>? leafPredictors]) {
  final tokens = EntropyEncoder(contextCount: 6);
  for (final _ContextTreeNode node in tree._orderedNodes) {
    if (node.propertyIndex < 0) {
      tokens.write(1, 0); // property + 1 == 0 -> leaf
      tokens.write(2, leafPredictors != null ? leafPredictors[node.context] : predictor);
      tokens.write(3, 0); // offset
      tokens.write(4, 0); // mul_log
      tokens.write(5, 0); // mul_bits
    } else {
      tokens.write(1, tree.properties[node.propertyIndex] + 1);
      tokens.write(0, _packSigned(node.value));
    }
  }
  tokens.finalize(w);
}

/// Packs signed.
int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

/// Assigns the context (leaf id) for a property vector by walking the tree.
int contextFor(ContextTree tree, Int32List propsAt) {
  _ContextTreeNode node = tree._root;
  while (node.propertyIndex >= 0) {
    node = propsAt[node.propertyIndex] > node.value ? node.left! : node.right!;
  }
  return node.context;
}
