/// Trade-off between JPEG XL encoding speed and output size.
///
/// The encoder can search many ways of coding the same image and keep the
/// smallest result. That search is what makes lossless JPEG XL compact, and
/// also what makes it slow: every extra candidate costs another full pass over
/// the image. This enum selects how much of that search to run.
enum JpegXlEffort {
  /// Codes the image once, with no search.
  ///
  /// Uses the clamped-gradient predictor, one entropy configuration, and no
  /// per-leaf predictor refinement. Several times faster than [maximum] for a
  /// few percent larger output.
  fast(
    triesBothPredictors: false,
    refinesBothPredictors: false,
    refinesLeafPredictors: false,
    triesEveryEntropyConfig: false,
    triesDeepLz77: false,
    assemblesNearTies: false,
  ),

  /// Picks the better predictor, then codes the image once with it.
  ///
  /// Keeps the predictor choice, which is the single decision that most
  /// affects size, but never runs the full pipeline twice.
  balanced(
    triesBothPredictors: true,
    refinesBothPredictors: false,
    refinesLeafPredictors: true,
    triesEveryEntropyConfig: true,
    triesDeepLz77: false,
    assemblesNearTies: true,
  ),

  /// Searches every candidate and keeps the smallest output.
  maximum(
    triesBothPredictors: true,
    refinesBothPredictors: true,
    refinesLeafPredictors: true,
    triesEveryEntropyConfig: true,
    triesDeepLz77: true,
    assemblesNearTies: true,
  );

  /// Whether both predictors get a full residual pass and a learned tree.
  final bool triesBothPredictors;

  /// Whether a near-tie between the predictors runs the whole pipeline twice.
  final bool refinesBothPredictors;

  /// Whether individual tree leaves may switch to the other predictor.
  final bool refinesLeafPredictors;

  /// Whether every hybrid-integer configuration is evaluated.
  final bool triesEveryEntropyConfig;

  /// Whether the deep LZ77 matcher is tried once LZ77 is already winning.
  final bool triesDeepLz77;

  /// Whether candidates close to the best estimate are assembled for real.
  final bool assemblesNearTies;

  /// Creates an effort level from the search steps it enables.
  const JpegXlEffort({
    required this.triesBothPredictors,
    required this.refinesBothPredictors,
    required this.refinesLeafPredictors,
    required this.triesEveryEntropyConfig,
    required this.triesDeepLz77,
    required this.assemblesNearTies,
  });
}
