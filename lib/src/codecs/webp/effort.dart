/// Trade-off between lossy WebP encoding speed and output quality.
///
/// A lossy WebP encoder spends most of its time deciding how to predict each
/// macroblock and how to round its coefficients. Every extra candidate costs
/// another transform, quantization and reconstruction pass. This enum selects
/// how much of that search to run.
enum WebPEffort {
  /// Picks prediction modes by squared error alone and never splits a
  /// macroblock into sixteen four-by-four blocks.
  ///
  /// This is the fastest setting. Detailed areas keep more blocking than they
  /// would at [balanced], because a single sixteen-by-sixteen prediction has
  /// to cover the whole macroblock.
  fast(
    weighsRateAgainstDistortion: false,
    triesIntra4x4: false,
    refinesCoefficients: false,
  ),

  /// Weighs the coded size of every candidate against its error, and tries
  /// splitting each macroblock into four-by-four blocks.
  ///
  /// This is the default. It is the setting where most of the quality per byte
  /// is won.
  balanced(
    weighsRateAgainstDistortion: true,
    triesIntra4x4: true,
    refinesCoefficients: false,
  ),

  /// Adds a local rate-distortion search around every quantized coefficient.
  ///
  /// Testing both neighboring levels can preserve detail that scalar rounding
  /// would discard or remove a level whose coded cost outweighs its accuracy.
  maximum(
    weighsRateAgainstDistortion: true,
    triesIntra4x4: true,
    refinesCoefficients: true,
  );

  /// Whether prediction modes are compared by coded size plus error rather
  /// than by error alone.
  final bool weighsRateAgainstDistortion;

  /// Whether a macroblock may be split into sixteen four-by-four predictions.
  final bool triesIntra4x4;

  /// Whether neighboring quantized coefficient levels are compared.
  final bool refinesCoefficients;

  /// Creates an effort level from the searches it enables.
  const WebPEffort({
    required this.weighsRateAgainstDistortion,
    required this.triesIntra4x4,
    required this.refinesCoefficients,
  });
}
