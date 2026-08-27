part of '../../webp.dart';

/// Number of coefficient block types.
const int _vp8TypeCount = 4;

/// Number of coefficient frequency bands.
const int _vp8BandCount = 8;

/// Number of neighboring non-zero contexts.
const int _vp8ContextCount = 3;

/// Number of probabilities describing one coefficient position.
const int _vp8ProbabilityCount = 11;

/// Total number of coefficient probabilities in one frame.
const int _vp8ProbabilityTotal = _vp8TypeCount * _vp8BandCount * _vp8ContextCount * _vp8ProbabilityCount;

/// Largest coefficient magnitude the bitstream can carry.
const int _vp8MaximumLevel = 2047;

/// Fixed-point precision used by the quantizer reciprocal.
const int _vp8QuantizerFractionBits = 17;

/// Bit cost unit, where 256 stands for one bit.
const int _vp8BitCostUnit = 256;

/// Index of a coefficient probability inside a flattened frame table.
int _vp8ProbabilityIndex(int type, int band, int context, int position) => (((type * _vp8BandCount + band) * _vp8ContextCount) + context) * _vp8ProbabilityCount + position;

/// Holds the constant tables shared by every lossy WebP encode.
///
/// The decoder already carries the same tables in the shapes it needs. These
/// are the flattened, typed forms the encoder indexes in its inner loops.
abstract final class _Vp8EncoderTables {
  /// Frequency band of each coefficient position, with a seventeenth entry so
  /// that a lookup past the last coefficient stays in range.
  static final Uint8List bands = Uint8List.fromList(_Vp8Decoder._coefficientBands);

  /// Coefficient positions in the order they are coded.
  static final Uint8List zigzag = Uint8List.fromList(_Vp8Decoder._zigzagOrder);

  /// Default coefficient probabilities, flattened.
  static final Uint8List defaultProbabilities = _flattenProbabilities(_Vp8Decoder._defaultCoefficientProbabilities);

  /// Probability that a coefficient probability is updated, flattened.
  static final Uint8List updateProbabilities = _flattenProbabilities(_Vp8Decoder._coefficientUpdateProbabilities);

  /// Cost in 1/256 bit of coding a zero with each probability.
  ///
  /// Coding a one with probability `p` costs the same as coding a zero with
  /// `255 - p`, so this single table serves both.
  static final Int32List entropyCosts = _buildEntropyCosts();

  /// Cost of the constant-probability bits and the sign of each magnitude.
  static final Int32List fixedLevelCosts = _buildFixedLevelCosts();

  /// Amount added to each luma coefficient before quantization.
  ///
  /// Nudging the higher frequencies up keeps a little more texture at the
  /// quantizer levels where a plain rounding would flatten it.
  static const List<int> frequencySharpening = <int>[0, 30, 60, 90, 30, 60, 90, 90, 60, 90, 90, 90, 90, 90, 90, 90];

  /// Rounding bias for direct-current and alternating-current coefficients of
  /// luma, second-order luma, and chroma blocks.
  static const List<List<int>> quantizerBias = <List<int>>[
    <int>[96, 110],
    <int>[96, 108],
    <int>[110, 115],
  ];

  /// Probability index of each decision leading to a four-by-four mode.
  static final List<Uint8List> intra4PathNodes = _buildIntra4Paths().$1;

  /// Bit written at each decision leading to a four-by-four mode.
  static final List<Uint8List> intra4PathBits = _buildIntra4Paths().$2;

  /// Cost of coding a zero with [probability].
  static int zeroCost(int probability) => entropyCosts[probability];

  /// Cost of coding a one with [probability].
  static int oneCost(int probability) => entropyCosts[255 - probability];

  /// Cost of coding [bit] with [probability].
  static int bitCost(int bit, int probability) => bit != 0 ? entropyCosts[255 - probability] : entropyCosts[probability];

  /// Flattens the decoder's nested probability tables.
  static Uint8List _flattenProbabilities(List<List<List<List<int>>>> source) {
    final Uint8List flattened = Uint8List(_vp8ProbabilityTotal);
    int index = 0;
    for (final List<List<List<int>>> type in source) {
      for (final List<List<int>> band in type) {
        for (final List<int> context in band) {
          for (final int probability in context) {
            flattened[index++] = probability;
          }
        }
      }
    }
    return flattened;
  }

  /// Builds the entropy cost table from the definition of a bit's cost.
  static Int32List _buildEntropyCosts() {
    final Int32List costs = Int32List(256);
    for (int probability = 1; probability < 256; ++probability) {
      costs[probability] = (-_vp8BitCostUnit * (math.log(probability / 256) / math.ln2)).round();
    }
    // A probability of zero says the bit is never a zero. Nothing pays this
    // cost, but the table must stay finite for the comparisons that read it.
    costs[0] = costs[1];
    return costs;
  }

  /// Builds the cost of the bits every magnitude codes with fixed
  /// probabilities, including its sign.
  static Int32List _buildFixedLevelCosts() {
    final Int32List costs = Int32List(_vp8MaximumLevel + 1);
    for (int level = 1; level <= _vp8MaximumLevel; ++level) {
      int cost = _vp8BitCostUnit; // The sign is written with no model.
      if (level == 5 || level == 6) {
        cost += bitCost(level == 6 ? 1 : 0, 159);
      } else if (level >= 7 && level <= 10) {
        cost += bitCost(level >= 9 ? 1 : 0, 165);
        cost += bitCost(level.isEven ? 1 : 0, 145);
      } else if (level > 10) {
        final (List<int> table, int mask, int residue) = categoryOf(level);
        for (int bit = mask, index = 0; bit != 0; bit >>= 1, ++index) {
          cost += bitCost((residue & bit) != 0 ? 1 : 0, table[index]);
        }
      }
      costs[level] = cost;
    }
    return costs;
  }

  /// Extra-bit table, top bit mask, and offset magnitude of a large [level].
  static (List<int>, int, int) categoryOf(int level) {
    final int residue = level - 3;
    if (residue < 8 << 1) {
      return (_Vp8Decoder._category3Probabilities, 1 << 2, residue - (8 << 0));
    }
    if (residue < 8 << 2) {
      return (_Vp8Decoder._category4Probabilities, 1 << 3, residue - (8 << 1));
    }
    if (residue < 8 << 3) {
      return (_Vp8Decoder._category5Probabilities, 1 << 4, residue - (8 << 2));
    }
    return (_Vp8Decoder._category6Probabilities, 1 << 10, residue - (8 << 3));
  }

  /// Walks the four-by-four mode tree once and records the path to each mode.
  static (List<Uint8List>, List<Uint8List>) _buildIntra4Paths() {
    final List<Uint8List> nodes = List<Uint8List>.filled(10, Uint8List(0));
    final List<Uint8List> bits = List<Uint8List>.filled(10, Uint8List(0));

    /// Visits both branches below one encoded tree [node].
    void walk(int node, List<int> pathNodes, List<int> pathBits) {
      for (int bit = 0; bit < 2; ++bit) {
        final int next = _Vp8Decoder._intra4ModeTree[node + bit];
        final List<int> childNodes = <int>[...pathNodes, node >> 1];
        final List<int> childBits = <int>[...pathBits, bit];
        if (next > 0) {
          walk(2 * next, childNodes, childBits);
        } else {
          nodes[-next] = Uint8List.fromList(childNodes);
          bits[-next] = Uint8List.fromList(childBits);
        }
      }
    }

    walk(0, <int>[], <int>[]);
    return (nodes, bits);
  }
}
