import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Configures the self-correcting weighted predictor used by modular streams.
final class WeightedPredictorParameters {
  /// Scales the combined error used by the north-based candidate.
  final int northPredictionErrorScale;

  /// Scales the combined error used by the west-based candidate.
  final int westPredictionErrorScale;

  /// Scales the northwest error used by the gradient candidate.
  final int northwestErrorScale;

  /// Scales the north error used by the gradient candidate.
  final int northErrorScale;

  /// Scales the northeast error used by the gradient candidate.
  final int northeastErrorScale;

  /// Scales the vertical gradient used by the gradient candidate.
  final int verticalGradientScale;

  /// Scales the horizontal gradient used by the gradient candidate.
  final int horizontalGradientScale;

  /// Provides the base weight for each predictor candidate.
  final List<int> predictorWeights;

  /// Reads weighted-predictor parameters from [reader].
  factory WeightedPredictorParameters.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return const WeightedPredictorParameters._(
        northPredictionErrorScale: 16,
        westPredictionErrorScale: 10,
        northwestErrorScale: 7,
        northErrorScale: 7,
        northeastErrorScale: 7,
        verticalGradientScale: 0,
        horizontalGradientScale: 0,
        predictorWeights: [13, 12, 12, 12],
      );
    }
    final int northPredictionErrorScale = reader.readBits(5);
    final int westPredictionErrorScale = reader.readBits(5);
    final int northwestErrorScale = reader.readBits(5);
    final int northErrorScale = reader.readBits(5);
    final int northeastErrorScale = reader.readBits(5);
    final int verticalGradientScale = reader.readBits(5);
    final int horizontalGradientScale = reader.readBits(5);
    final predictorWeights = List<int>.generate(4, (_) => reader.readBits(4));
    return WeightedPredictorParameters._(
      northPredictionErrorScale: northPredictionErrorScale,
      westPredictionErrorScale: westPredictionErrorScale,
      northwestErrorScale: northwestErrorScale,
      northErrorScale: northErrorScale,
      northeastErrorScale: northeastErrorScale,
      verticalGradientScale: verticalGradientScale,
      horizontalGradientScale: horizontalGradientScale,
      predictorWeights: predictorWeights,
    );
  }

  /// Creates weighted-predictor parameters from decoded values.
  const WeightedPredictorParameters._({
    required this.northPredictionErrorScale,
    required this.westPredictionErrorScale,
    required this.northwestErrorScale,
    required this.northErrorScale,
    required this.northeastErrorScale,
    required this.verticalGradientScale,
    required this.horizontalGradientScale,
    required this.predictorWeights,
  });
}
