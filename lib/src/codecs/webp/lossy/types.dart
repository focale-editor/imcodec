part of '../../webp.dart';

/// Number of quantized values stored for one VP8 macroblock.
const int _vp8MacroblockCoefficientCount = 400;

/// First coefficient of the eight chroma blocks.
const int _vp8ChromaCoefficientOffset = 16 * 16;

/// First coefficient of the secondary luma block.
const int _vp8SecondaryLumaCoefficientOffset = 24 * 16;

/// Holds padded source and reconstructed YUV 4:2:0 planes.
final class _Vp8LossyPlanes {
  /// Source luma samples.
  final Uint8List luma;

  /// Source blue-difference chroma samples.
  final Uint8List blueDifference;

  /// Source red-difference chroma samples.
  final Uint8List redDifference;

  /// Reconstructed luma samples used by later predictions.
  final Uint8List reconstructedLuma;

  /// Reconstructed blue-difference samples used by later predictions.
  final Uint8List reconstructedBlueDifference;

  /// Reconstructed red-difference samples used by later predictions.
  final Uint8List reconstructedRedDifference;

  /// Uncompressed alpha samples, or `null` for an opaque image.
  final Uint8List? alpha;

  /// Padded number of luma samples in one row.
  final int lumaStride;

  /// Padded number of chroma samples in one row.
  final int chromaStride;

  /// Creates the planes used throughout one encode.
  const _Vp8LossyPlanes({
    required this.luma,
    required this.blueDifference,
    required this.redDifference,
    required this.reconstructedLuma,
    required this.reconstructedBlueDifference,
    required this.reconstructedRedDifference,
    required this.alpha,
    required this.lumaStride,
    required this.chromaStride,
  });
}

/// Describes scalar quantization for one VP8 coefficient block type.
final class _Vp8EncoderQuantizationMatrix {
  /// Dequantization step indexed by natural coefficient position.
  final Int32List steps;

  /// Fixed-point reciprocal of each [steps] entry.
  final Int32List reciprocals;

  /// Fixed-point rounding bias for each coefficient.
  final Int32List biases;

  /// Small luma-only frequency boost applied before quantization.
  final Int32List sharpening;

  /// Creates a matrix from direct-current and alternating-current steps.
  _Vp8EncoderQuantizationMatrix({
    required int directCurrentStep,
    required int alternatingCurrentStep,
    required int biasType,
    required bool sharpensLuma,
  }) : steps = Int32List(16),
       reciprocals = Int32List(16),
       biases = Int32List(16),
       sharpening = Int32List(16) {
    for (int index = 0; index < 16; ++index) {
      final bool isAlternatingCurrent = index != 0;
      final int step = isAlternatingCurrent ? alternatingCurrentStep : directCurrentStep;
      final int bias = _Vp8EncoderTables.quantizerBias[biasType][isAlternatingCurrent ? 1 : 0];
      steps[index] = step;
      reciprocals[index] = (1 << _vp8QuantizerFractionBits) ~/ step;
      biases[index] = bias << (_vp8QuantizerFractionBits - 8);
      sharpening[index] = sharpensLuma ? (_Vp8EncoderTables.frequencySharpening[index] * step) >> 11 : 0;
    }
  }
}

/// Holds every quantization matrix selected by one quality setting.
final class _Vp8EncoderQuantizers {
  /// Quantizer index written to the frame header.
  final int index;

  /// Matrix for ordinary luma blocks.
  final _Vp8EncoderQuantizationMatrix luma;

  /// Matrix for the secondary luma direct-current block.
  final _Vp8EncoderQuantizationMatrix secondaryLuma;

  /// Matrix for blue- and red-difference blocks.
  final _Vp8EncoderQuantizationMatrix chroma;

  /// Rate-distortion multiplier in squared-error units.
  final int lambda;

  /// Creates all matrices for [index].
  _Vp8EncoderQuantizers({
    required this.index,
  }) : luma = _Vp8EncoderQuantizationMatrix(
         directCurrentStep: _Vp8Decoder._directCurrentQuantizers[index],
         alternatingCurrentStep: _Vp8Decoder._alternatingCurrentQuantizers[index],
         biasType: 0,
         sharpensLuma: true,
       ),
       secondaryLuma = _Vp8EncoderQuantizationMatrix(
         directCurrentStep: _Vp8Decoder._directCurrentQuantizers[index] * 2,
         alternatingCurrentStep: math.max(
           8,
           (_Vp8Decoder._alternatingCurrentQuantizers[index] * 101581) >> 16,
         ),
         biasType: 1,
         sharpensLuma: false,
       ),
       chroma = _Vp8EncoderQuantizationMatrix(
         directCurrentStep: _Vp8Decoder._directCurrentQuantizers[math.min(index, 117)],
         alternatingCurrentStep: _Vp8Decoder._alternatingCurrentQuantizers[index],
         biasType: 2,
         sharpensLuma: false,
       ),
       lambda = math.max(
         1,
         (3 * _Vp8Decoder._alternatingCurrentQuantizers[index] * _Vp8Decoder._alternatingCurrentQuantizers[index]) >> 7,
       );
}

/// Stores the decisions and quantized coefficients of one macroblock.
final class _Vp8LossyMacroblock {
  /// Whether luma uses sixteen independent predictions.
  final bool isIntra4x4;

  /// Four-by-four luma modes, or the macroblock mode in the first entry.
  final Uint8List lumaModes;

  /// Eight-by-eight chroma prediction mode.
  final int chromaMode;

  /// Quantized coefficients in coded order.
  final Int16List coefficients;

  /// Whether every residual coefficient is zero.
  final bool skip;

  /// Creates a completed macroblock.
  const _Vp8LossyMacroblock({
    required this.isIntra4x4,
    required this.lumaModes,
    required this.chromaMode,
    required this.coefficients,
    required this.skip,
  });
}

/// Carries one fully evaluated luma prediction choice.
final class _Vp8LumaCandidate {
  /// Whether this choice uses four-by-four predictions.
  final bool isIntra4x4;

  /// Selected modes in raster block order.
  final Uint8List modes;

  /// Quantized luma and secondary-luma coefficients.
  final Int16List coefficients;

  /// Reconstructed sixteen-by-sixteen samples.
  final Uint8List reconstruction;

  /// Rate-distortion score used to compare this choice.
  final int score;

  /// Creates an evaluated luma choice.
  const _Vp8LumaCandidate({
    required this.isIntra4x4,
    required this.modes,
    required this.coefficients,
    required this.reconstruction,
    required this.score,
  });
}

/// Carries one fully evaluated chroma prediction choice.
final class _Vp8ChromaCandidate {
  /// Selected eight-by-eight prediction mode.
  final int mode;

  /// Quantized coefficients for four blocks in each chroma plane.
  final Int16List coefficients;

  /// Reconstructed blue-difference samples.
  final Uint8List blueDifference;

  /// Reconstructed red-difference samples.
  final Uint8List redDifference;

  /// Rate-distortion score used to compare this choice.
  final int score;

  /// Creates an evaluated chroma choice.
  const _Vp8ChromaCandidate({
    required this.mode,
    required this.coefficients,
    required this.blueDifference,
    required this.redDifference,
    required this.score,
  });
}
