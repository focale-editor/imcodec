import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/image_buffer.dart' show floatMatrix;
import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Describes one transform-specific set of dequantization parameters.
final class DctQuantizationParameters {
  /// Parameters for the primary DCT weight model.
  final List<List<double>>? dctParameters;

  /// Weights applied to quantization.
  final List<List<double>>? quantizationWeights;

  /// Parameters for the nested four-by-four DCT weight model.
  final List<List<double>>? dct4x4Parameters;

  /// Mode identifier for the DCT quantization parameters.
  final int mode;

  /// Scale denominator applied when expanding the parameters.
  final double denominator;

  /// Creates a transform-specific quantization description.
  const DctQuantizationParameters({
    required this.dctParameters,
    required this.quantizationWeights,
    required this.mode,
    this.dct4x4Parameters,
    this.denominator = 1,
  });
}

/// Lists the reference frequencies for the asymmetric frequency-varying transform.
const _afvFrequencies = <double>[
  0, 0, 0.8517778890324296, 5.37778436506804, //
  0, 0, 4.734747904497923, 5.449245381693219, //
  1.6598270267479331, 4, 7.275749096817861, 10.423227632456525, //
  2.662932286148962, 7.630657783650829, 8.962388608184032, 12.97166202570235,
];

/// Defines the first default quantization-frequency sequence.
const _firstQuantizationSequence = <double>[
  -1.025, -0.78, -0.65012, -0.19041574084286472, -0.20819395464, -0.421064,
  -0.32733845535848671, //
];

/// Defines the second default quantization-frequency sequence.
const _secondQuantizationSequence = <double>[
  -0.3041958212306401, -0.3633036457487539, -0.35660379990111464,
  -0.3443074455424403, -0.33699592683512467, -0.30180866526242109,
  -0.27321683125358037, //
];

/// Defines the third default quantization-frequency sequence.
const _thirdQuantizationSequence = <double>[-1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5];

/// Returns [remainingValues] with [firstValue] inserted at the beginning.
List<double> _prepend(double firstValue, List<double> remainingValues) => [firstValue, ...remainingValues];

/// Defines the nested four-by-four DCT quantization parameters.
const _dct4x4Parameters = <List<double>>[
  [2200, 0.0, 0.0, 0.0],
  [392, 0.0, 0.0, 0.0],
  [112, -0.25, -0.25, -0.5],
];

/// Defines the four-by-eight DCT quantization parameters.
const _dct4x8Parameters = <List<double>>[
  [2198.050556016380522, -0.96269623020744692, -0.76194253026666783, -0.6551140670773547], //
  [764.3655248643528689, -0.92630200888366945, -0.9675229603596517, -0.27845290869168118], //
  [527.107573587542228, -1.4594385811273854, -1.450082094097871593, -1.5843722511996204], //
];

/// Default DCT quantization parameters used by the high frequency global implementation.
final List<DctQuantizationParameters> defaultDctQuantizationParameters = [
  const DctQuantizationParameters(
    dctParameters: [
      [3150.0, 0.0, -0.4, -0.4, -0.4, -2.0],
      [560.0, 0.0, -0.3, -0.3, -0.3, -0.3],
      [512.0, -2.0, -1.0, 0.0, -1.0, -2.0],
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
  const DctQuantizationParameters(
    dctParameters: null,
    quantizationWeights: [
      [280.0, 3160.0, 3160.0],
      [60.0, 864.0, 864.0],
      [18.0, 200.0, 200.0],
    ],
    mode: TransformMode.hornuss,
  ),
  const DctQuantizationParameters(
    dctParameters: null,
    quantizationWeights: [
      [3840.0, 2560.0, 1280.0, 640.0, 480.0, 300.0],
      [960.0, 640.0, 320.0, 180.0, 140.0, 120.0],
      [640.0, 320.0, 128.0, 64.0, 32.0, 16.0],
    ],
    mode: TransformMode.dct2,
  ),
  const DctQuantizationParameters(
    dctParameters: _dct4x4Parameters,
    quantizationWeights: [
      [1.0, 1.0],
      [1.0, 1.0],
      [1.0, 1.0],
    ],
    mode: TransformMode.dct4,
    dct4x4Parameters: _dct4x4Parameters,
  ),
  const DctQuantizationParameters(
    dctParameters: [
      [8996.8725711814115328, -1.3000777393353804, -0.49424529824571225, -0.439093774457103443, -0.6350101832695744, -0.90177264050827612, -1.6162099239887414], //
      [3191.48366296844234752, -0.67424582104194355, -0.80745813428471001, -0.44925837484843441, -0.35865440981033403, -0.31322389111877305, -0.37615025315725483], //
      [1157.50408145487200256, -2.0531423165804414, -1.4, -0.50687130033378396, -0.42708730624733904, -1.4856834539296244, -4.9209142884401604], //
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
  const DctQuantizationParameters(
    dctParameters: [
      [15718.40830982518931456, -1.025, -0.98, -0.9012, -0.4, -0.48819395464, -0.421064, -0.27], //
      [7305.7636810695983104, -0.8041958212306401, -0.7633036457487539, -0.55660379990111464, -0.49785304658857626, -0.43699592683512467, -0.40180866526242109, -0.27321683125358037], //
      [3803.53173721215041536, -3.060733579805728, -2.0413270132490346, -2.0235650159727417, -0.5495389509954993, -0.4, -0.4, -0.3], //
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
  const DctQuantizationParameters(
    dctParameters: [
      [7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5],
      [1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2],
      [506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6],
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
  const DctQuantizationParameters(
    dctParameters: [
      [16283.2494710648897, -1.7812845336559429, -1.6309059012653515, -1.0382179034313539, -0.85, -0.7, -0.9, -1.2360638576849587], //
      [5089.15750884921511936, -0.320049391452786891, -0.35362849922161446, -0.30340000000000003, -0.61, -0.5, -0.5, -0.6], //
      [3397.77603275308720128, -0.321327362693153371, -0.34507619223117997, -0.70340000000000003, -0.9, -1.0, -1.0, -1.1754605576265209], //
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
  const DctQuantizationParameters(
    dctParameters: [
      [13844.97076442300573, -0.97113799999999995, -0.658, -0.42026, -0.22712, -0.2206, -0.226, -0.6], //
      [4798.964084220744293, -0.61125308982767057, -0.83770786552491361, -0.79014862079498627, -0.2692727459704829, -0.38272769465388551, -0.22924222653091453, -0.20719098826199578], //
      [1807.236946760964614, -1.2, -1.2, -0.7, -0.7, -0.7, -0.4, -0.5], //
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
  const DctQuantizationParameters(
    dctParameters: _dct4x8Parameters,
    quantizationWeights: [
      [1.0],
      [1.0],
      [1.0],
    ],
    mode: TransformMode.dct4x8,
  ),
  const DctQuantizationParameters(
    dctParameters: _dct4x8Parameters,
    quantizationWeights: [
      [3072, 3072, 256, 256, 256, 414, 0.0, 0.0, 0.0],
      [1024, 1024, 50.0, 50.0, 50.0, 58, 0.0, 0.0, 0.0],
      [384, 384, 12.0, 12.0, 12.0, 22, -0.25, -0.25, -0.25],
    ],
    mode: TransformMode.afv,
    dct4x4Parameters: _dct4x4Parameters,
  ),

  DctQuantizationParameters(
    dctParameters: [
      _prepend(23966.1665298448605, _firstQuantizationSequence),
      _prepend(8380.19148390090414, _secondQuantizationSequence),
      _prepend(4493.02378009847706, _thirdQuantizationSequence),
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),

  DctQuantizationParameters(
    dctParameters: [
      _prepend(15358.89804933239925, _firstQuantizationSequence),
      _prepend(5597.360516150652990, _secondQuantizationSequence),
      _prepend(2919.961618960011210, _thirdQuantizationSequence),
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),

  DctQuantizationParameters(
    dctParameters: [
      _prepend(47932.3330596897210, _firstQuantizationSequence),
      _prepend(16760.38296780180828, _secondQuantizationSequence),
      _prepend(8986.04756019695412, _thirdQuantizationSequence),
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),

  DctQuantizationParameters(
    dctParameters: [
      _prepend(30717.796098664792, _firstQuantizationSequence),
      _prepend(11194.72103230130598, _secondQuantizationSequence),
      _prepend(5839.92323792002242, _thirdQuantizationSequence),
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),

  DctQuantizationParameters(
    dctParameters: [
      _prepend(95864.6661193794420, _firstQuantizationSequence),
      _prepend(33520.76593560361656, _secondQuantizationSequence),
      _prepend(17972.09512039390824, _thirdQuantizationSequence),
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
  // DCT 256x128 / 128x256 (parameterIndex 16). libjxl's DCT128X256 default
  // uses the *rectangular* per-channel base weights (2.6 * 23629.07 /
  // 8611.32 / 4492.25), not the square ones. jxlatte transcribed channels 1
  // and 2 from the square series (2.6 * 9311.32 / 4992.25) by mistake — an
  // off-by-exactly-1820/-1300 error in the DC band that we inherited
  // verbatim. It only surfaces when this transform is chosen with default
  // (non-custom) quant weights, i.e. distance 1.0: our decoder used the same
  // wrong table so round-trips were self-consistent, but djxl (correct)
  // diverged. See doc/spec_notes.md and ROADMAP.md.
  DctQuantizationParameters(
    dctParameters: [
      _prepend(61435.5921973295970, _firstQuantizationSequence),
      _prepend(22389.44206460261196, _secondQuantizationSequence),
      _prepend(11679.84647584004484, _thirdQuantizationSequence),
    ],
    quantizationWeights: null,
    mode: TransformMode.dct,
  ),
];

/// Converts a signed quantization delta into its multiplicative factor.
double _quantizationMultiplier(double value) => value >= 0 ? 1.0 + value : 1.0 / (1.0 - value);

/// Geometrically interpolates a quantization weight at [scaledPosition].
double _interpolateQuantizationWeight(double scaledPosition, List<double> bands) {
  final int lastIndex = bands.length - 1;
  if (lastIndex == 0) {
    return bands[0];
  }
  final int scaledIndex = scaledPosition.truncate();
  final double fractionalIndex = scaledPosition - scaledIndex;
  if (scaledIndex + 1 > lastIndex) {
    return bands[lastIndex];
  }
  final double lowerWeight = bands[scaledIndex];
  final double upperWeight = bands[scaledIndex + 1];
  return lowerWeight * math.pow(upperWeight / lowerWeight, fractionalIndex);
}

/// Computes the raw (pre-inversion) DCT quantization weight matrix for one
/// channel. Public so the lossy encoder can mirror it exactly when choosing
/// quantization steps (the decoder inverts this matrix per weight).
List<Float32List> getDctQuantizationWeights(int height, int width, List<double> quantizationParameters) {
  final bands = List<double>.filled(quantizationParameters.length, 0);
  bands[0] = quantizationParameters[0];
  for (var i = 1; i < bands.length; i++) {
    bands[i] = bands[i - 1] * _quantizationMultiplier(quantizationParameters[i]);
  }
  final List<Float32List> weights = List.generate(height, (_) => Float32List(width), growable: false);
  final double scale = (bands.length - 1) / (math.sqrt2 + 1e-6);
  for (var y = 0; y < height; y++) {
    final double dy = y * scale / (height - 1);
    final double dy2 = dy * dy;
    for (var x = 0; x < width; x++) {
      final double dx = x * scale / (width - 1);
      final double dist = math.sqrt(dx * dx + dy2);
      weights[y][x] = _interpolateQuantizationWeight(dist, bands);
    }
  }
  return weights;
}

/// Computes the raw (pre-inversion) DCT4x4 quantization weight matrix for
/// one channel: a 2x-nearest-neighbor-upsampled 4x4 quant-weight table (see
/// [getDctQuantizationWeights]) with 3 low-frequency positions overridden by
/// [overrides] (`target[1][0]`, `target[0][1]` divided by `overrides[0]`,
/// `target[1][1]` divided by `overrides[1]`). Public for the same reason as
/// [getDctQuantizationWeights] itself: so the lossy encoder can build the exact
/// same table it quantizes against as what this file writes to the
/// bitstream and what the decoder rebuilds — single-sourced, not
/// independently re-derived (see `var_dct_encoder.dart`'s
/// `rawWeightByType`).
List<Float32List> getDct4x4QuantizationWeights(List<double> dctParameters, List<double> overrides) {
  final List<Float32List> target = floatMatrix(8, 8);
  final List<Float32List> w = getDctQuantizationWeights(4, 4, dctParameters);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      target[y][x] = w[y ~/ 2][x ~/ 2];
    }
  }
  target[1][0] /= overrides[0];
  target[0][1] /= overrides[0];
  target[1][1] /= overrides[1];
  return target;
}

/// Computes the raw (pre-inversion) Hornuss quantization weight matrix for
/// one channel: [quantizationWeights] holds 3 absolute weight values used directly (not a
/// band-interpolated table) — `quantizationWeights[0]` fills every position, then
/// `quantizationWeights[1]` overrides the two positions adjacent to the LLF corner and
/// `quantizationWeights[2]` overrides the position diagonal to it; the LLF corner itself
/// is fixed at 1.0 (it's dequantized from the DC plane, never from this
/// table). Public for the same single-sourcing reason as
/// [getDct4x4QuantizationWeights].
List<Float32List> getHornussQuantizationWeights(List<double> quantizationWeights) {
  final List<Float32List> w = floatMatrix(8, 8);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      w[y][x] = quantizationWeights[0];
    }
  }
  w[1][1] = quantizationWeights[2];
  w[0][1] = w[1][0] = quantizationWeights[1];
  w[0][0] = 1.0;
  return w;
}

/// Computes the raw (pre-inversion) DCT2x2 quantization weight matrix for
/// one channel: [quantizationWeights] holds 6 absolute weight values, tiered to match the
/// 3-stage cascade's own tiered structure — `quantizationWeights[0]`/`quantizationWeights[1]` cover the
/// top-left 2x2 (minus the LLF corner, fixed at 1.0), `quantizationWeights[2]`/`quantizationWeights[3]`
/// the ring completing the 4x4, `quantizationWeights[4]`/`quantizationWeights[5]` the ring completing
/// the full 8x8. Public for the same single-sourcing reason as
/// [getDct4x4QuantizationWeights].
List<Float32List> getDct2x2QuantizationWeights(List<double> quantizationWeights) {
  final List<Float32List> w = floatMatrix(8, 8);
  w[0][0] = 1.0;
  w[0][1] = w[1][0] = quantizationWeights[0];
  w[1][1] = quantizationWeights[1];
  for (var y = 0; y < 2; y++) {
    for (var x = 0; x < 2; x++) {
      w[y][x + 2] = w[x + 2][y] = quantizationWeights[2];
      w[y + 2][x + 2] = quantizationWeights[3];
    }
  }
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      w[y][x + 4] = w[x + 4][y] = quantizationWeights[4];
      w[y + 4][x + 4] = quantizationWeights[5];
    }
  }
  return w;
}

/// Computes the raw (pre-inversion) DCT4x8/DCT8x4 quantization weight
/// matrix for one channel: a 2x-nearest-neighbor-upsampled 4x8 quant-weight
/// table (see [getDctQuantizationWeights]), upsampled only along the height axis
/// (the sub-block DCTs this shares are already 8 wide), with one
/// low-frequency position overridden by [override] (`target[1][0]` divided
/// by it — the same "override is a divisor on a separately-built base
/// table" shape as [getDct4x4QuantizationWeights], not an absolute weight like
/// [getHornussQuantizationWeights]/[getDct2x2QuantizationWeights]). Shared by both
/// DCT4x8 and DCT8x4 (same `parameterIndex`, distinguished only by
/// `var_dct_inverter.dart`'s reconstruction switch). Public for the same
/// single-sourcing reason as [getDct4x4QuantizationWeights].
List<Float32List> getDct4x8QuantizationWeights(List<double> dctParameters, double override) {
  final List<Float32List> target = floatMatrix(8, 8);
  final List<Float32List> w = getDctQuantizationWeights(4, 8, dctParameters);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      target[y][x] = w[y ~/ 2][x];
    }
  }
  target[1][0] /= override;
  return target;
}

/// Computes the raw (pre-inversion) AFV0-3 quantization weight matrix for
/// one channel: the 8x8 table is partitioned into 3 disjoint regions
/// matching `var_dct_inverter.dart`'s `_invertAfv` reconstruction exactly —
/// the "even row, even column" positions (`weight[2x][2y]`) belong to the
/// AFV-basis region (6 positions from [dctParameters]/[dct4x4Parameters]-independent
/// direct overrides in [quantizationWeights], the rest from
/// [_afvFrequencies]-indexed band
/// interpolation seeded by [quantizationWeights]); the "even row, odd column" positions
/// belong to the transposed-4x4-DCT region ([dct4x4Parameters], via
/// [getDctQuantizationWeights]); the "odd row, any column" positions belong to
/// the 4x8-DCT region ([dctParameters], via [getDctQuantizationWeights]). Public for
/// the same single-sourcing reason as [getDct4x4QuantizationWeights].
List<Float32List> getAfvQuantizationWeights(List<double> dctParameters, List<double> dct4x4Parameters, List<double> quantizationWeights) {
  final List<Float32List> weights4x8 = getDctQuantizationWeights(4, 8, dctParameters);
  final List<Float32List> weights4x4 = getDctQuantizationWeights(4, 4, dct4x4Parameters);
  const low = 0.8517778890324296;
  const high = 12.97166202570235;
  final bands = List<double>.filled(4, 0);
  bands[0] = quantizationWeights[5];
  if (bands[0] < 0) {
    throw const JpegXlInvalidBitstreamException(message: 'negative band value');
  }
  for (var i = 1; i < 4; i++) {
    bands[i] = bands[i - 1] * _quantizationMultiplier(quantizationWeights[i + 5]);
    if (bands[i] < 0) {
      throw const JpegXlInvalidBitstreamException(message: 'negative band value');
    }
  }
  final List<Float32List> weight = floatMatrix(8, 8);
  weight[0][0] = 1.0;
  weight[1][0] = quantizationWeights[0];
  weight[0][1] = quantizationWeights[1];
  weight[2][0] = quantizationWeights[2];
  weight[0][2] = quantizationWeights[3];
  weight[2][2] = quantizationWeights[4];
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      if (x < 2 && y < 2) {
        continue;
      }
      final double position = (_afvFrequencies[y * 4 + x] - low) / (high - low);
      weight[2 * x][2 * y] = _interpolateQuantizationWeight(position, bands);
    }
    for (var x = 0; x < 8; x++) {
      if (x == 0 && y == 0) {
        continue;
      }
      weight[2 * y + 1][x] = weights4x8[y][x];
    }
    for (var x = 0; x < 4; x++) {
      if (x == 0 && y == 0) {
        continue;
      }
      weight[2 * y][2 * x + 1] = weights4x4[y][x];
    }
  }
  return weight;
}

/// Holds frame-wide high-frequency dequantization weights and entropy presets.
final class HighFrequencyGlobal {
  /// Quantization description selected for each transform mode.
  late final List<DctQuantizationParameters> quantizationParameters;

  /// Whether weights have been expanded for each transform type.
  final List<bool> _weightsReady = List<bool>.filled(17, false);

  /// Expanded dequantization matrices by transform and color channel.
  late final List<List<List<Float32List>?>> weights;

  /// Flattened dequantization matrices by transform and color channel.
  late final List<List<Float32List?>> flattenedWeights;

  /// Four-lane dequantization matrices by transform and color channel.
  late final List<List<Float32x4List?>> vectorWeights;

  /// Transposed four-lane matrices by transform and color channel.
  late final List<List<Float32x4List?>> transposedVectorWeights;

  /// Row widths for the flattened matrices.
  late final List<int> weightWidths;

  /// Number of entropy presets declared for high-frequency coefficients.
  late final int highFrequencyPresetCount;

  /// Reads the frame-wide high-frequency quantization configuration.
  HighFrequencyGlobal({
    required BitReader reader,
    required Frame frame,
  }) {
    final bool useDefaultQuantization = reader.readBool();
    if (useDefaultQuantization) {
      quantizationParameters = defaultDctQuantizationParameters;
    } else {
      quantizationParameters = List.generate(17, (i) => _readQuantizationParameters(reader, frame, i));
    }
    weights = List.generate(17, (_) => List<List<Float32List>?>.filled(3, null));
    // Weight generation, including large-matrix interpolation, is deferred to
    // first use per parameter index: most images use few transform types.
    flattenedWeights = List.generate(17, (_) => List<Float32List?>.filled(3, null));
    vectorWeights = List.generate(17, (_) => List<Float32x4List?>.filled(3, null));
    transposedVectorWeights = List.generate(17, (_) => List<Float32x4List?>.filled(3, null));
    weightWidths = List<int>.filled(17, 0);
    highFrequencyPresetCount = 1 + reader.readBits(ceilLog1p(frame.groupCount - 1));
  }

  /// Generates (once) and returns the flattened weight matrices for a
  /// parameter index.
  List<Float32List?> flattenedWeightsFor(int index) {
    if (!_weightsReady[index]) {
      _generateWeights(index);
      for (var ch = 0; ch < 3; ch++) {
        final List<Float32List>? w = weights[index][ch];
        if (w == null) {
          continue;
        }
        final int rows = w.length;
        final int cols = w[0].length;
        weightWidths[index] = cols;
        final flat = Float32List(rows * cols);
        for (var y = 0; y < rows; y++) {
          flat.setRange(y * cols, (y + 1) * cols, w[y]);
        }
        flattenedWeights[index][ch] = flat;
        vectorWeights[index][ch] = Float32x4List.view(flat.buffer, 0, flat.length >> 2);
        // Transposed copy: flipped transforms read weights column-major,
        // which this turns back into row-major (y * pixelWidth + x).
        final flatT = Float32List(rows * cols);
        for (var y = 0; y < rows; y++) {
          for (var x = 0; x < cols; x++) {
            flatT[x * rows + y] = flat[y * cols + x];
          }
        }
        transposedVectorWeights[index][ch] = Float32x4List.view(flatT.buffer, 0, flatT.length >> 2);
      }
      _weightsReady[index] = true;
    }
    return flattenedWeights[index];
  }

  /// Reads dctparams.
  static List<List<double>> _readDctParameters(BitReader reader) {
    final int numParams = 1 + reader.readBits(4);
    return List.generate(3, (c) {
      final vals = List<double>.generate(numParams, (_) => reader.readF16());
      vals[0] *= 64.0;
      return vals;
    });
  }

  /// Builds DCT quantizationWeights.
  DctQuantizationParameters _readQuantizationParameters(BitReader reader, Frame frame, int index) {
    final int encodingMode = reader.readBits(3);
    TransformType.validateIndex(index, encodingMode);
    switch (encodingMode) {
      case TransformMode.library:
        return defaultDctQuantizationParameters[index];
      case TransformMode.hornuss:
        // *64 confirmed correct (not dct4's bug below): these 3 values are
        // absolute weight-table entries used directly (see
        // getHornussQuantizationWeights), the same role a dct-shaped table's own
        // band[0] plays via _readDctParameters -- verified via djxl round-trips
        // once the lossy encoder could exercise a *custom* Hornuss quant
        // table with non-degenerate content (vardct_l0_test.dart's
        // "weight-table override positions carry real signal" test). See
        // doc/spec_notes.md.
        final List<List<double>> m = List.generate(3, (_) => List<double>.generate(3, (_) => 64.0 * reader.readF16()));
        return DctQuantizationParameters(dctParameters: null, quantizationWeights: m, mode: encodingMode);
      case TransformMode.dct2:
        // *64 confirmed correct for the same reason as hornuss above (see
        // getDct2x2QuantizationWeights and vardct_l0_test.dart's "weight-table
        // ring positions carry real signal" test).
        final List<List<double>> m = List.generate(3, (_) => List<double>.generate(6, (_) => 64.0 * reader.readF16()));
        return DctQuantizationParameters(dctParameters: null, quantizationWeights: m, mode: encodingMode);
      case TransformMode.dct4:
        // NOT *64 (unlike hornuss/dct2 above, and unlike a dct-shaped
        // table's own first value via _readDctParameters) -- a real decoder
        // bug, found and fixed via the lossy encoder's DCT4x4 support
        // (var_dct_encoder.dart): reading these 2 raw overrides per
        // channel with *64 (matching hornuss/dct2's own pattern, and
        // jxlatte's identical inherited mistake) round-trips through this
        // decoder perfectly but was found to disagree with djxl once an
        // encoder could actually exercise a *custom* (non-default) DCT4x4
        // quant table -- nothing ever had before, since no natural corpus
        // file happens to trigger it. See doc/spec_notes.md. Confirmed NOT
        // shared by hornuss/dct2 (see above) -- the distinguishing factor
        // is that these 2 dct4 values are DIVISORS layered on a separate
        // base table, not absolute weights themselves.
        final List<List<double>> m = List.generate(3, (_) => List<double>.generate(2, (_) => reader.readF16()));
        return DctQuantizationParameters(dctParameters: _readDctParameters(reader), quantizationWeights: m, mode: encodingMode);
      case TransformMode.dct:
        return DctQuantizationParameters(dctParameters: _readDctParameters(reader), quantizationWeights: null, mode: encodingMode);
      case TransformMode.raw:
        final double den = reader.readF16();
        final TransformType tt = TransformType.byParameterIndex(index);
        final info = [
          ModularChannel(height: tt.matrixHeight, width: tt.matrixWidth, verticalShift: 0, horizontalShift: 0),
          ModularChannel(height: tt.matrixHeight, width: tt.matrixWidth, verticalShift: 0, horizontalShift: 0),
          ModularChannel(height: tt.matrixHeight, width: tt.matrixWidth, verticalShift: 0, horizontalShift: 0),
        ];
        final stream = ModularStream.read(reader: reader, context: frame.modularContext, streamIndex: 1 + 3 * frame.lowFrequencyGroupCount + index, channelArray: info);
        stream.decodeChannels(reader);
        final List<List<double>> m = List.generate(3, (_) => List<double>.filled(tt.matrixHeight * tt.matrixWidth, 0));
        for (var c = 0; c < 3; c++) {
          final ModularChannel chan = stream.getChannel(c);
          final Int32List b = chan.buffer!;
          for (var i = 0; i < b.length; i++) {
            m[c][i] = b[i].toDouble();
          }
        }
        return DctQuantizationParameters(dctParameters: null, quantizationWeights: m, mode: encodingMode, denominator: den);
      case TransformMode.dct4x8:
        // NOT *64 already, matching dct4's fixed convention (this override
        // is a divisor on a separately-built base table -- see
        // getDct4x8QuantizationWeights -- the same shape as dct4's overrides, not
        // hornuss/dct2's absolute-weight shape). Confirmed correct via
        // djxl round-trips at non-default distances with content carrying
        // real, nonzero signal at the override position for both DCT4x8
        // and DCT8x4 (vardct_l0_test.dart's "genuinely wins on a
        // step+gradient pattern" tests) -- not assumed correct just
        // because the read code already looked right. See
        // doc/spec_notes.md.
        final List<List<double>> m = List.generate(3, (_) => List<double>.generate(1, (_) => reader.readF16()));
        return DctQuantizationParameters(dctParameters: _readDctParameters(reader), quantizationWeights: m, mode: encodingMode);
      case TransformMode.afv:
        // Indices 0-4 (the 5 corner overrides, e.g. weight[1][0]=quantizationWeights[0])
        // and 5 (bands[0], the AFV-basis region's own interpolation seed)
        // are ALL absolute weight-table values used directly -- like
        // hornuss/dct2's quantizationParameters, which legitimately get *64 -- not
        // dct4/dct4x8's divisor-on-a-separate-table shape (which does NOT
        // get *64). Indices 6-8 (quantMult ratios feeding the band chain)
        // correctly don't get *64, matching a dct-shaped table's own
        // vals[1:]. Confirmed correct via djxl round-trips at non-default
        // distances across all 4 AFV variants, with content specifically
        // chosen (a flat-corner-plus-gradient pattern, not a degenerate
        // periodic one) so every region -- including the AFV-basis region
        // this type's own decoder comment ("SPEC: watch signs here")
        // flags as elevated risk -- carries real, nonzero signal. See
        // doc/spec_notes.md.
        final List<List<double>> m = List.generate(3, (_) => List<double>.generate(9, (x) => x < 6 ? 64.0 * reader.readF16() : reader.readF16()));
        final List<List<double>> d = _readDctParameters(reader);
        final List<List<double>> f = _readDctParameters(reader);
        return DctQuantizationParameters(dctParameters: d, quantizationWeights: m, mode: encodingMode, dct4x4Parameters: f);
      default:
        throw const JpegXlInvalidBitstreamException(message: 'invalid quant mode');
    }
  }

  /// Expands AFV weights for one transform and color channel.
  List<Float32List> _getAfvTransformWeights(int index, int c) {
    final DctQuantizationParameters p = quantizationParameters[index];
    return getAfvQuantizationWeights(p.dctParameters![c], p.dct4x4Parameters![c], p.quantizationWeights![c]);
  }

  /// Generates weights.
  void _generateWeights(int index) {
    final TransformType tt = TransformType.byParameterIndex(index);
    final DctQuantizationParameters p = quantizationParameters[index];
    for (var c = 0; c < 3; c++) {
      switch (p.mode) {
        case TransformMode.dct:
          weights[index][c] = getDctQuantizationWeights(tt.matrixHeight, tt.matrixWidth, p.dctParameters![c]);
        case TransformMode.dct4:
          weights[index][c] = getDct4x4QuantizationWeights(p.dctParameters![c], p.quantizationWeights![c]);
        case TransformMode.dct2:
          weights[index][c] = getDct2x2QuantizationWeights(p.quantizationWeights![c]);
        case TransformMode.hornuss:
          weights[index][c] = getHornussQuantizationWeights(p.quantizationWeights![c]);
        case TransformMode.dct4x8:
          weights[index][c] = getDct4x8QuantizationWeights(p.dctParameters![c], p.quantizationWeights![c][0]);
        case TransformMode.afv:
          weights[index][c] = _getAfvTransformWeights(index, c);
        case TransformMode.raw:
          final List<Float32List> w = floatMatrix(tt.matrixHeight, tt.matrixWidth);
          for (var y = 0; y < tt.matrixHeight; y++) {
            for (var x = 0; x < tt.matrixWidth; x++) {
              w[y][x] = p.quantizationWeights![c][y * tt.matrixWidth + x] * p.denominator;
            }
          }
          weights[index][c] = w;
        default:
          throw const JpegXlInvalidBitstreamException(message: 'invalid quant mode');
      }
    }
    if (p.mode != TransformMode.raw) {
      for (var c = 0; c < 3; c++) {
        final List<Float32List> w = weights[index][c]!;
        for (var y = 0; y < tt.matrixHeight; y++) {
          for (var x = 0; x < tt.matrixWidth; x++) {
            if (w[y][x] <= 0 || !w[y][x].isFinite) {
              throw const JpegXlInvalidBitstreamException(message: 'negative or infinite quant weight');
            }
            w[y][x] = 1.0 / w[y][x];
          }
        }
      }
    }
  }
}
