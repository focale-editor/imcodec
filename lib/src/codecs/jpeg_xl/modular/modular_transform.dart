import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Selects the channels and direction of one modular squeeze operation.
final class SqueezeParameters {
  /// Whether samples are squeezed horizontally rather than vertically.
  final bool horizontal;

  /// Whether the residual channels replace the selected source channels.
  final bool inPlace;

  /// Index of the first affected channel.
  final int firstChannel;

  /// Number of consecutive affected channels.
  final int channelCount;

  /// Creates parameters for a modular squeeze operation.
  SqueezeParameters({
    required this.horizontal,
    required this.inPlace,
    required this.firstChannel,
    required this.channelCount,
  });

  /// Reads squeeze parameters from [reader].
  SqueezeParameters.read({
    required BitReader reader,
  }) : horizontal = reader.readBool(),
       inPlace = reader.readBool(),
       firstChannel = reader.readU32(0, 3, 8, 6, 72, 10, 1096, 13),
       channelCount = reader.readU32(1, 0, 2, 0, 3, 0, 4, 4);
}

/// One entry of a modular stream's transform chain.
final class ModularTransform {
  /// Identifies a reversible color transform.
  static const int reversibleColor = 0;

  /// Identifies a palette transform.
  static const int palette = 1;

  /// Identifies a squeeze transform.
  static const int squeeze = 2;

  /// Transform identifier read from the codestream.
  final int type;

  /// Index of the first affected channel.
  final int firstChannel;

  /// Permutation and transformation variant used for reversible color data.
  final int reversibleColorTransformType;

  /// Number of consecutive affected channels.
  final int channelCount;

  /// Number of entries in a decoded palette.
  final int colorCount;

  /// Number of palette entries encoded as deltas.
  final int deltaCount;

  /// Predictor used to reconstruct delta-coded palette entries.
  final int deltaPredictor;

  /// Explicit squeeze operations, or `null` when the defaults are used.
  final List<SqueezeParameters>? squeezeParameters;

  /// Reads one modular transform from [reader].
  factory ModularTransform.read({
    required BitReader reader,
  }) {
    final int type = reader.readBits(2);
    final int firstChannel = type != squeeze ? reader.readU32(0, 3, 8, 6, 72, 10, 1096, 13) : 0;
    final int reversibleColorTransformType = type == reversibleColor ? reader.readU32(6, 0, 0, 2, 2, 4, 10, 6) : 0;
    int channelCount = 0;
    int colorCount = 0;
    int deltaCount = 0;
    int deltaPredictor = 0;
    if (type == palette) {
      channelCount = reader.readU32(1, 0, 3, 0, 4, 0, 1, 13);
      colorCount = reader.readU32(0, 8, 256, 10, 1280, 12, 5376, 16);
      deltaCount = reader.readU32(0, 0, 1, 8, 257, 10, 1281, 16);
      deltaPredictor = reader.readBits(4);
    }
    List<SqueezeParameters>? squeezeParameters;
    if (type == squeeze) {
      final int squeezeCount = reader.readU32(0, 0, 1, 4, 9, 6, 41, 8);
      squeezeParameters = List.generate(squeezeCount, (_) => SqueezeParameters.read(reader: reader));
    }
    return ModularTransform._(
      type: type,
      firstChannel: firstChannel,
      reversibleColorTransformType: reversibleColorTransformType,
      channelCount: channelCount,
      colorCount: colorCount,
      deltaCount: deltaCount,
      deltaPredictor: deltaPredictor,
      squeezeParameters: squeezeParameters,
    );
  }

  /// Creates a decoded modular transform.
  ModularTransform._({
    required this.type,
    required this.firstChannel,
    required this.reversibleColorTransformType,
    required this.channelCount,
    required this.colorCount,
    required this.deltaCount,
    required this.deltaPredictor,
    required this.squeezeParameters,
  });
}
