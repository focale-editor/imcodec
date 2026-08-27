import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// A meta-adaptive tree: inner nodes test a property against a value, leaves
/// carry (context, predictor, offset, multiplier).
final class MetaAdaptiveTree {
  /// Inner-node fields; property < 0 marks a leaf.
  int property = -1;

  /// Threshold used to choose between child nodes.
  int value = 0;

  /// Serialized index of the child selected above [value].
  int _leftChildIndex = 0;

  /// Serialized index of the child selected at or below [value].
  int _rightChildIndex = 0;

  /// Child selected when the tested property is greater than [value].
  MetaAdaptiveTree? left;

  /// Child selected when the tested property is at most [value].
  MetaAdaptiveTree? right;

  /// Leaf fields.
  int context = 0;

  /// Predictor identifier selected by this leaf.
  int predictor = -1;

  /// Offset added to predictions made by this leaf.
  int offset = 0;

  /// Multiplier applied to residuals decoded by this leaf.
  int multiplier = 1;

  /// The residual entropy stream (shared by all nodes of one tree).
  EntropyStream? stream;

  /// Cached result exposed by [needsResolution].
  bool? _needsResolution;

  /// Creates an empty node while the tree is being decoded.
  MetaAdaptiveTree._();

  /// Reads the tree and its associated entropy stream (used later to decode
  /// the actual pixel residuals).
  factory MetaAdaptiveTree.read({
    required BitReader reader,
  }) {
    final nodes = <MetaAdaptiveTree>[];
    final stream = EntropyStream.read(reader: reader, distributionCount: 6);
    var contextId = 0;
    var nodesRemaining = 1;
    MetaAdaptiveTree? root;
    while (nodesRemaining-- > 0) {
      if (nodes.length > 1 << 20) {
        throw const JpegXlInvalidBitstreamException(message: 'MA tree too large');
      }
      final int property = stream.readSymbol(reader, 1) - 1;
      final node = MetaAdaptiveTree._();
      root ??= node;
      if (property >= 0) {
        node.property = property;
        node.value = unpackSigned(stream.readSymbol(reader, 0));
        final int leftChild = nodes.length + nodesRemaining + 1;
        node._leftChildIndex = leftChild;
        node._rightChildIndex = leftChild + 1;
        nodes.add(node);
        nodesRemaining += 2;
      } else {
        node.context = contextId++;
        node.predictor = stream.readSymbol(reader, 2);
        if (node.predictor > 13) {
          throw const JpegXlInvalidBitstreamException(message: 'invalid predictor value');
        }
        node.offset = unpackSigned(stream.readSymbol(reader, 3));
        final int mulLog = stream.readSymbol(reader, 4);
        if (mulLog > 30) {
          throw const JpegXlInvalidBitstreamException(message: 'mulLog too large');
        }
        final int mulBits = stream.readSymbol(reader, 5);
        if (mulBits > (1 << (31 - mulLog)) - 2) {
          throw const JpegXlInvalidBitstreamException(message: 'mulBits too large');
        }
        node.multiplier = (mulBits + 1) << mulLog;
        nodes.add(node);
      }
    }
    if (!stream.validateFinalState()) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal MA tree entropy state');
    }

    root!.stream = EntropyStream.read(reader: reader, distributionCount: (nodes.length + 1) ~/ 2);
    for (final node in nodes) {
      node.stream = root.stream;
      if (!node.isLeaf) {
        node.left = nodes[node._leftChildIndex];
        node.right = nodes[node._rightChildIndex];
      }
    }
    return root;
  }

  /// Whether this node contains a prediction leaf.
  bool get isLeaf => property < 0;

  /// Whether the tree selects the weighted predictor.
  bool get usesWeightedPredictor {
    if (isLeaf) {
      return predictor == 6;
    }
    return property == 15 || left!.usesWeightedPredictor || right!.usesWeightedPredictor;
  }

  /// Whether this subtree tests channel index, stream index or y (properties
  /// 0-2) anywhere — that is, whether [resolveStaticProperties] can do anything but return
  /// `this` unchanged. Real learned trees (this project's own encoder and,
  /// empirically, cjxl's) split almost exclusively on spatial/gradient
  /// properties (3+), so this is `false` for entire trees in practice.
  bool get needsResolution {
    final bool? cached = _needsResolution;
    if (cached != null) {
      return cached;
    }
    final bool result = !isLeaf && (property <= 2 || left!.needsResolution || right!.needsResolution);
    return _needsResolution = result;
  }

  /// Resolves properties that are constant across a channel row
  /// (channel index, stream index, y), returning a smaller tree. Called once
  /// per row of every channel decode, so subtrees that don't test properties
  /// 0-2 anywhere must short-circuit rather than reallocate a full copy of
  /// themselves on every call (see [needsResolution]).
  MetaAdaptiveTree resolveStaticProperties(int channelIndex, int streamIndex, int y) {
    if (isLeaf || !needsResolution) {
      return this;
    }
    final int prop = switch (property) {
      0 => channelIndex,
      1 => streamIndex,
      2 => y,
      _ => -1,
    };
    if (prop >= 0) {
      final MetaAdaptiveTree branch = prop > value ? left! : right!;
      return branch.resolveStaticProperties(channelIndex, streamIndex, y);
    }
    final tree = MetaAdaptiveTree._();
    tree.property = property;
    tree.value = value;
    tree.left = left!.resolveStaticProperties(channelIndex, streamIndex, y);
    tree.right = right!.resolveStaticProperties(channelIndex, streamIndex, y);
    return tree;
  }
}
