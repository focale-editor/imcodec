import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/weighted_prediction.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/limits.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/meta_adaptive_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/weighted_predictor_parameters.dart';

/// Clamps [value] to the range spanned by two neighboring samples.
@pragma('vm:prefer-inline')
int _clampBetween(int value, int first, int second) {
  final int lower = first < second ? first : second;
  // max(a, b) via a plain comparison, not `lower ^ a ^ b`: a, b are
  // channel sample values, which can be negative (e.g. RCT chroma
  // channels) - dart2js's `^` reinterprets a negative operand as its
  // unsigned-32-bit equivalent and never converts the result back, so a
  // max that should come out negative comes out as a huge positive
  // number there instead.
  final int upper = first < second ? second : first;
  return value < lower
      ? lower
      : value > upper
      ? upper
      : value;
}

/// Squeeze "tendency" (the smooth predictor of the squeeze transform).
int tendency(int a, int b, int c) {
  if (a >= b && b >= c) {
    int x = (4 * a - 3 * c - b + 6) ~/ 12;
    final int d = 2 * (a - b);
    final int e = 2 * (b - c);
    if (x - (x & 1) > d) {
      x = d + 1;
    }
    if (x + (x & 1) > e) {
      x = e;
    }
    return x;
  }
  if (a <= b && b <= c) {
    int x = (4 * a - 3 * c - b - 6) ~/ 12;
    final int d = 2 * (a - b);
    final int e = 2 * (b - c);
    if (x + (x & 1) < d) {
      x = d - 1;
    }
    if (x - (x & 1) < e) {
      x = e;
    }
    return x;
  }
  return 0;
}

/// One channel of a modular (sub-)stream: geometry, pixel buffer, and the
/// per-pixel decode loop with all 14 predictors including the
/// self-correcting weighted predictor.
final class ModularChannel {
  /// Stores the fourth weighted-predictor error row.
  Int32List? _predictionError3;

  /// Height in pixels.
  int height;

  /// Width in pixels.
  int width;

  /// Base-two vertical downsampling shift relative to the frame.
  int verticalShift;

  /// Base-two horizontal downsampling shift relative to the frame.
  int horizontalShift;

  /// Horizontal sample origin within the parent channel.
  int horizontalOrigin = 0;

  /// Vertical sample origin within the parent channel.
  int verticalOrigin = 0;

  /// Whether the channel always uses weighted prediction.
  bool forceWeightedPredictor;

  /// Whether the channel samples have been decoded.
  bool decoded = false;

  /// Flat pixel buffer, row stride == [width].
  Int32List? buffer;

  // Weighted-predictor state, live only during decode(). _predictionError0-4 mirror
  // libjxl's `pred_errors`/`error` (uint32_t/int32_t, narrow -- summed and
  // re-masked or re-truncated by their readers, see _weightedPredictorPlaneWeight and the
  // main decode loop's `_weightedPredictionError` write). _weightedPrediction/_predictorCandidates mirror libjxl's
  // `pred`/`prediction[]` (`pixel_type_w`, i.e. int64_t): NOT narrowed
  // until they're finally combined into a stored (int32) pixel value, so
  // these must stay wide.
  /// Stores the first weighted-predictor error row.
  Int32List? _predictionError0;

  /// Stores the second weighted-predictor error row.
  Int32List? _predictionError1;

  /// Stores the third weighted-predictor error row.
  Int32List? _predictionError2;

  /// Stores the current weighted-predictor error row.
  Int32List? _weightedPredictionError;

  /// Wide intermediate value produced by weighted prediction.
  Int64List? _weightedPrediction;

  /// Candidate predictor values used by the weighted predictor.
  final Int64List _predictorCandidates = Int64List(4);

  /// Creates a modular channel.
  ModularChannel({
    required this.height,
    required this.width,
    required this.verticalShift,
    required this.horizontalShift,
    this.forceWeightedPredictor = false,
  });

  /// Creates an independent copy.
  ModularChannel.copy({
    required ModularChannel other,
  }) : height = other.height,
       width = other.width,
       verticalShift = other.verticalShift,
       horizontalShift = other.horizontalShift,
       forceWeightedPredictor = other.forceWeightedPredictor,
       horizontalOrigin = other.horizontalOrigin,
       verticalOrigin = other.verticalOrigin,
       decoded = other.decoded {
    if (other.buffer != null) {
      buffer = Int32List.fromList(other.buffer!);
    }
  }

  /// Allocates storage for the decoded samples.
  void allocate() {
    if (height < 0 || width < 0 || (width != 0 && height > JpegXlLimits.maxPlanePixels ~/ width)) {
      throw JpegXlInvalidBitstreamException(message: 'channel ${width}x$height exceeds JpegXlLimits.maxPlanePixels');
    }
    buffer ??= Int32List(height * width);
  }

  /// Returns the value at the requested position.
  @pragma('vm:prefer-inline')
  int sampleAt(int y, int x) => buffer![y * width + x];

  /// Stores [value] at the requested sample position.
  void setSample(int y, int x, int value) => buffer![y * width + x] = value;

  /// Whether [other] has the same sample dimensions.
  bool sizeEquals(ModularChannel other) => height == other.height && width == other.width;

  // Neighbor accessors with the spec's border fallbacks. o == y * width + x.
  /// Returns the west neighbor using the specification's border fallback.
  @pragma('vm:prefer-inline')
  int _west(Int32List b, int o, int x, int y) => x > 0
      ? b[o - 1]
      : y > 0
      ? b[o - width]
      : 0;

  /// Returns the north neighbor using the specification's border fallback.
  @pragma('vm:prefer-inline')
  int _north(Int32List b, int o, int x, int y) => y > 0
      ? b[o - width]
      : x > 0
      ? b[o - 1]
      : 0;

  /// Returns the northwest neighbor using the specification's border fallback.
  @pragma('vm:prefer-inline')
  int _northWest(Int32List b, int o, int x, int y) => x > 0 ? (y > 0 ? b[o - width - 1] : b[o - 1]) : (y > 0 ? b[o - width] : 0);

  /// Returns the northeast neighbor using the specification's border fallback.
  @pragma('vm:prefer-inline')
  int _northEast(Int32List b, int o, int x, int y) => x + 1 < width && y > 0 ? b[o - width + 1] : _north(b, o, x, y);

  /// Returns the sample two rows north using the border fallback.
  @pragma('vm:prefer-inline')
  int _northNorth(Int32List b, int o, int x, int y) => y > 1 ? b[o - 2 * width] : _north(b, o, x, y);

  /// Returns the sample one row north and two columns east.
  @pragma('vm:prefer-inline')
  int _northEastEast(Int32List b, int o, int x, int y) => x + 2 < width && y > 0 ? b[o - width + 2] : _northEast(b, o, x, y);

  /// Inverse vertical squeeze.
  static ModularChannel inverseVerticalSqueeze(ModularChannel channel, ModularChannel orig, ModularChannel res) {
    if (channel.height != orig.height + res.height || orig.height != res.height && orig.height != 1 + res.height || channel.width != orig.width || res.width != orig.width) {
      throw const JpegXlInvalidBitstreamException(message: 'corrupted squeeze transform');
    }
    channel.allocate();
    final Int32List cb = channel.buffer!;
    final Int32List ob = orig.buffer!;
    final Int32List rb = res.buffer!;
    final int w = channel.width;
    for (var y = 0; y < res.height; y++) {
      for (var x = 0; x < w; x++) {
        final int avg = ob[y * w + x];
        final int residu = rb[y * w + x];
        final int nextAvg = y + 1 < orig.height ? ob[(y + 1) * w + x] : avg;
        final int top = y > 0 ? cb[(2 * y - 1) * w + x] : avg;
        final int diff = residu + tendency(top, avg, nextAvg);
        final int first = avg + diff ~/ 2;
        cb[2 * y * w + x] = first;
        cb[(2 * y + 1) * w + x] = first - diff;
      }
    }
    if (orig.height > res.height) {
      cb.setRange(2 * res.height * w, (2 * res.height + 1) * w, ob, res.height * w);
    }
    return channel;
  }

  /// Returns the west prediction error or zero at the border.
  @pragma('vm:prefer-inline')
  int _errWest(Int32List e, int o, int x) => x > 0 ? e[o - 1] : 0;

  /// Returns the north prediction error or zero at the border.
  @pragma('vm:prefer-inline')
  int _errNorth(Int32List e, int o, int y) => y > 0 ? e[o - width] : 0;

  /// Returns the northwest prediction error using the border fallback.
  @pragma('vm:prefer-inline')
  int _errNorthWest(Int32List e, int o, int x, int y) => x > 0 && y > 0 ? e[o - width - 1] : _errNorth(e, o, y);

  /// Returns the northeast prediction error using the border fallback.
  @pragma('vm:prefer-inline')
  int _errNorthEast(Int32List e, int o, int x, int y) => x + 1 < width && y > 0 ? e[o - width + 1] : _errNorth(e, o, y);

  /// Predictor k at (y, x). Used both during decode and by the palette
  /// transform's delta prediction.
  int prediction(int y, int x, int k) {
    final Int32List b = buffer!;
    final int o = y * width + x;
    switch (k) {
      case 0:
        return 0;
      case 1:
        return x > 0
            ? b[o - 1]
            : y > 0
            ? b[o - width]
            : 0;
      case 2:
        return y > 0
            ? b[o - width]
            : x > 0
            ? b[o - 1]
            : 0;
      case 3:
        // NOT truncated to 32 bits: libjxl computes every predictor
        // (context_predict.h's `PredictOne`) in `pixel_type_w` (int64_t),
        // not `pixel_type` (int32_t) -- only the *stored* pixel value
        // (`trueValue` in the caller) is ever narrowed to 32 bits. An
        // earlier session added `.toSigned(32)` truncation here on the
        // (wrong) assumption that jxlatte's Java `int` arithmetic was the
        // reference semantics; jxlatte has no float-sample support at all
        // (see doc/spec_notes.md), so that assumption was never exercised
        // against wide-range content and was never checked against
        // libjxl's actual (wider) types. Confirmed via direct libjxl
        // source read (lib/jxl/modular/encoding/context_predict.h).
        return (_west(b, o, x, y) + _north(b, o, x, y)) ~/ 2;
      case 4:
        final int w = _west(b, o, x, y);
        final int n = _north(b, o, x, y);
        final int nw = _northWest(b, o, x, y);
        // See case 3: no truncation -- matches libjxl's `Select`, computed
        // entirely in pixel_type_w.
        return (n - nw).abs() < (w - nw).abs() ? w : n;
      case 5:
        final int w = _west(b, o, x, y);
        final int n = _north(b, o, x, y);
        // See case 3: no truncation -- matches libjxl's `ClampedGradient`,
        // computed entirely in pixel_type_w.
        final int v = w + n - _northWest(b, o, x, y);
        return _clampBetween(v, n, w);
      case 6:
        return wideShrSigned(_weightedPrediction![o] + 3, 3);
      case 7:
        return _northEast(b, o, x, y);
      case 8:
        return _northWest(b, o, x, y);
      case 9:
        return _westWest(b, o, x, y);
      case 10:
        return (_west(b, o, x, y) + _northWest(b, o, x, y)) ~/ 2;
      case 11:
        return (_north(b, o, x, y) + _northWest(b, o, x, y)) ~/ 2;
      case 12:
        return (_north(b, o, x, y) + _northEast(b, o, x, y)) ~/ 2;
      case 13:
        // See case 3: no truncation -- matches libjxl's `PredictOne`'s
        // `Predictor::Average4` case, computed entirely in pixel_type_w
        // (confirmed: `(6 * top - 2 * toptop + 7 * left + 1 * leftleft +
        // 1 * toprightright + 3 * topright + 8) / 16` with no intermediate
        // narrowing anywhere in that expression).
        return (6 * _north(b, o, x, y) - 2 * _northNorth(b, o, x, y) + 7 * _west(b, o, x, y) + _westWest(b, o, x, y) + _northEastEast(b, o, x, y) + 3 * _northEast(b, o, x, y) + 8) ~/ 16;
      default:
        throw const JpegXlInvalidBitstreamException(message: 'illegal predictor');
    }
  }

  /// Computes a predictor weight with border-aware error samples.
  @pragma('vm:prefer-inline')
  int _weightedPredictorPlaneWeight(Int32List predictionErrors, int offset, int column, int row, int predictorWeight) => weightedPredictorPlaneWeight(
    predictionErrors: predictionErrors,
    offset: offset,
    column: column,
    row: row,
    width: width,
    predictorWeight: predictorWeight,
  );

  /// Computes a predictor weight for a pixel whose neighbors are all present.
  @pragma('vm:prefer-inline')
  int _interiorWeightedPredictorPlaneWeight(Int32List predictionErrors, int offset, int predictorWeight) {
    // See _weightedPredictorPlaneWeight's comment: masking to unsigned 32 bits mirrors
    // jxlatte's `eSum &= 0xffffffffL`, required for wide-range (float
    // sample) content.
    final int errorSum =
        (predictionErrors[offset - width] + predictionErrors[offset - 1] + predictionErrors[offset - width - 1] + predictionErrors[offset - 2] + predictionErrors[offset - width + 1]) & 0xffffffff;
    int shift = floorLog1p(errorSum) - 5;
    if (shift < 0) {
      shift = 0;
    }
    return 4 + ((predictorWeight * weightedPredictionReciprocalTable[errorSum >> shift]) >> shift);
  }

  /// [_prepareWeightedPrediction] for interior pixels (y > 1, 1 < x < width - 1):
  /// identical arithmetic with all border branches removed.
  int _prepareInteriorWeightedPrediction(WeightedPredictorParameters wp, int x, int y) {
    final Int32List b = buffer!;
    final int o = y * width + x;
    // NOT truncated to 32 bits: libjxl's `weighted::State::Predict`
    // (context_predict.h) computes N/W/NE/NW/NN, the error terms, and
    // `prediction[0-3]` entirely in `pixel_type_w` (int64_t) -- only
    // values actually stored into a narrower array (`pred_errors`, a
    // `vector<uint32_t>`; `error`, a `vector<int32_t>`) are ever narrowed,
    // at the point of that assignment. An earlier session added
    // `.toSigned(32)` truncation throughout this function on the (wrong)
    // assumption that jxlatte's Java `int` arithmetic was the reference
    // semantics; jxlatte has no float-sample support at all (see
    // doc/spec_notes.md), so that assumption was never exercised against
    // wide-range content and was never checked against libjxl's actual
    // (wider) types. `_predictionError0-4` (this class's narrow storage, matching
    // `pred_errors`/`error`) still narrow correctly at their own
    // assignment in [decode] -- only the *intermediate* truncation here
    // was wrong. Confirmed via direct libjxl source read.
    final int n3 = b[o - width] << 3;
    final int nw3 = b[o - width - 1] << 3;
    final int ne3 = b[o - width + 1] << 3;
    final int w3 = b[o - 1] << 3;
    final int nn3 = b[o - 2 * width] << 3;
    final Int32List e4 = _weightedPredictionError!;
    final int tN = e4[o - width];
    final int tW = e4[o - 1];
    final int tNE = e4[o - width + 1];
    final int tNW = e4[o - width - 1];
    _predictorCandidates[0] = w3 + ne3 - n3;
    _predictorCandidates[1] = n3 - wideShrSigned((tW + tN + tNE) * wp.northPredictionErrorScale, 5);
    _predictorCandidates[2] = w3 - wideShrSigned((tW + tN + tNW) * wp.westPredictionErrorScale, 5);
    _predictorCandidates[3] =
        n3 - wideShrSigned(tNW * wp.northwestErrorScale + tN * wp.northErrorScale + tNE * wp.northeastErrorScale + (nn3 - n3) * wp.verticalGradientScale + (nw3 - w3) * wp.horizontalGradientScale, 5);
    final List<int> predictorWeights = wp.predictorWeights;
    final int rw0 = _interiorWeightedPredictorPlaneWeight(_predictionError0!, o, predictorWeights[0]);
    final int rw1 = _interiorWeightedPredictorPlaneWeight(_predictionError1!, o, predictorWeights[1]);
    final int rw2 = _interiorWeightedPredictorPlaneWeight(_predictionError2!, o, predictorWeights[2]);
    final int rw3 = _interiorWeightedPredictorPlaneWeight(_predictionError3!, o, predictorWeights[3]);
    final int logWeight = floorLog1p(rw0 + rw1 + rw2 + rw3 - 1) - 4;
    final int sw0 = rw0 >> logWeight;
    final int sw1 = rw1 >> logWeight;
    final int sw2 = rw2 >> logWeight;
    final int sw3 = rw3 >> logWeight;
    final int wSum = sw0 + sw1 + sw2 + sw3;
    int s = (wSum >> 1) - 1;
    s += _predictorCandidates[0] * sw0;
    s += _predictorCandidates[1] * sw1;
    s += _predictorCandidates[2] * sw2;
    s += _predictorCandidates[3] * sw3;
    // wideShrSigned (not `>>`): the fixed-point product s * (2^24/k)
    // routinely exceeds 2^32 for ordinary pixel values, and s can be
    // negative - a bare `>>` truncates through a 32-bit int on dart2js,
    // silently corrupting the prediction (and everything downstream
    // that depends on it via the MA tree's error-based properties).
    int pred = wideShrSigned(s * weightedPredictionReciprocalTable[wSum - 1], 24);
    if (shouldClampWeightedPrediction(northError: tN, westError: tW, northWestError: tNW)) {
      pred = clampWeightedPrediction(value: pred, west: w3, north: n3, northEast: ne3);
    }
    _weightedPrediction![o] = pred;
    var maxError = tW;
    if (tN.abs() > maxError.abs()) {
      maxError = tN;
    }
    if (tNW.abs() > maxError.abs()) {
      maxError = tNW;
    }
    if (tNE.abs() > maxError.abs()) {
      maxError = tNE;
    }
    return maxError;
  }

  /// Computes the weighted-predictor subpredictions, weights, and prediction
  /// for pixel (y, x); returns maxError (MA-tree property 15).
  int _prepareWeightedPrediction(WeightedPredictorParameters wp, int x, int y) {
    final Int32List b = buffer!;
    final int o = y * width + x;
    // See _prepareInteriorWeightedPrediction's comment: not truncated to 32 bits --
    // libjxl computes this entirely in pixel_type_w (int64_t), narrowing
    // only at _predictionError0-4's own storage.
    final int n3 = _north(b, o, x, y) << 3;
    final int nw3 = _northWest(b, o, x, y) << 3;
    final int ne3 = _northEast(b, o, x, y) << 3;
    final int w3 = _west(b, o, x, y) << 3;
    final int nn3 = _northNorth(b, o, x, y) << 3;
    final Int32List e4 = _weightedPredictionError!;
    final int tN = _errNorth(e4, o, y);
    final int tW = _errWest(e4, o, x);
    final int tNE = _errNorthEast(e4, o, x, y);
    final int tNW = _errNorthWest(e4, o, x, y);
    _predictorCandidates[0] = w3 + ne3 - n3;
    _predictorCandidates[1] = n3 - wideShrSigned((tW + tN + tNE) * wp.northPredictionErrorScale, 5);
    _predictorCandidates[2] = w3 - wideShrSigned((tW + tN + tNW) * wp.westPredictionErrorScale, 5);
    _predictorCandidates[3] =
        n3 - wideShrSigned(tNW * wp.northwestErrorScale + tN * wp.northErrorScale + tNE * wp.northeastErrorScale + (nn3 - n3) * wp.verticalGradientScale + (nw3 - w3) * wp.horizontalGradientScale, 5);
    final List<int> predictorWeights = wp.predictorWeights;
    final int rw0 = _weightedPredictorPlaneWeight(_predictionError0!, o, x, y, predictorWeights[0]);
    final int rw1 = _weightedPredictorPlaneWeight(_predictionError1!, o, x, y, predictorWeights[1]);
    final int rw2 = _weightedPredictorPlaneWeight(_predictionError2!, o, x, y, predictorWeights[2]);
    final int rw3 = _weightedPredictorPlaneWeight(_predictionError3!, o, x, y, predictorWeights[3]);
    final int logWeight = floorLog1p(rw0 + rw1 + rw2 + rw3 - 1) - 4;
    final int sw0 = rw0 >> logWeight;
    final int sw1 = rw1 >> logWeight;
    final int sw2 = rw2 >> logWeight;
    final int sw3 = rw3 >> logWeight;
    final int wSum = sw0 + sw1 + sw2 + sw3;
    int s = (wSum >> 1) - 1;
    s += _predictorCandidates[0] * sw0;
    s += _predictorCandidates[1] * sw1;
    s += _predictorCandidates[2] * sw2;
    s += _predictorCandidates[3] * sw3;
    // wideShrSigned (not `>>`): the fixed-point product s * (2^24/k)
    // routinely exceeds 2^32 for ordinary pixel values, and s can be
    // negative - a bare `>>` truncates through a 32-bit int on dart2js,
    // silently corrupting the prediction (and everything downstream
    // that depends on it via the MA tree's error-based properties).
    int pred = wideShrSigned(s * weightedPredictionReciprocalTable[wSum - 1], 24);
    if (shouldClampWeightedPrediction(northError: tN, westError: tW, northWestError: tNW)) {
      pred = clampWeightedPrediction(value: pred, west: w3, north: n3, northEast: ne3);
    }
    _weightedPrediction![o] = pred;
    var maxError = tW;
    if (tN.abs() > maxError.abs()) {
      maxError = tN;
    }
    if (tNW.abs() > maxError.abs()) {
      maxError = tNW;
    }
    if (tNE.abs() > maxError.abs()) {
      maxError = tNE;
    }
    return maxError;
  }

  /// MA-tree property k for pixel (y, x). Properties 0-2 are handled by
  /// tree compactification and never reach here.
  int _property(List<ModularChannel> parentChannels, int channelIndex, int streamIndex, int k, int maxError, int y, int x) {
    final Int32List b = buffer!;
    final int o = y * width + x;
    switch (k) {
      case 0:
        return channelIndex;
      case 1:
        return streamIndex;
      case 2:
        return y;
      case 3:
        return x;
      case 4:
        return _north(b, o, x, y).abs();
      case 5:
        return _west(b, o, x, y).abs();
      case 6:
        return _north(b, o, x, y);
      case 7:
        return _west(b, o, x, y);
      // Cases 8-14 truncate to signed 32 bits, matching jxlatte's
      // auto-truncating Java `int` arithmetic (see case 3's comment in
      // [prediction]) -- these feed MA-tree property/context selection
      // directly, so an untruncated overflow here doesn't just mispredict
      // a pixel, it can pick the wrong entropy context and desync the
      // whole stream (surfacing far downstream as "illegal final modular
      // state" rather than at the point of the actual divergence).
      case 8:
        if (x <= 0) {
          return _west(b, o, x, y);
        }
        return (_west(b, o, x, y) - (_west(b, o - 1, x - 1, y) + _north(b, o - 1, x - 1, y) - _northWest(b, o - 1, x - 1, y)).toSigned(32)).toSigned(32);
      case 9:
        return (_west(b, o, x, y) + _north(b, o, x, y) - _northWest(b, o, x, y)).toSigned(32);
      case 10:
        return (_west(b, o, x, y) - _northWest(b, o, x, y)).toSigned(32);
      case 11:
        return (_northWest(b, o, x, y) - _north(b, o, x, y)).toSigned(32);
      case 12:
        return (_north(b, o, x, y) - _northEast(b, o, x, y)).toSigned(32);
      case 13:
        return (_north(b, o, x, y) - _northNorth(b, o, x, y)).toSigned(32);
      case 14:
        return (_west(b, o, x, y) - _westWest(b, o, x, y)).toSigned(32);
      case 15:
        return maxError;
      default:
        if (k - 16 >= 4 * channelIndex) {
          return 0;
        }
        var k2 = 16;
        for (int j = channelIndex - 1; j >= 0; j--) {
          final ModularChannel channel = parentChannels[j];
          if (!sizeEquals(channel) || verticalShift != channel.verticalShift || horizontalShift != channel.horizontalShift) {
            continue;
          }
          if (k2 + 4 <= k) {
            k2 += 4;
            continue;
          }
          final Int32List cb = channel.buffer!;
          final int rC = cb[o];
          if (k2++ == k) {
            return rC.abs();
          }
          if (k2++ == k) {
            return rC;
          }
          final int rW = x > 0 ? cb[o - 1] : 0;
          final int rN = y > 0 ? cb[o - width] : rW;
          final int rNW = x > 0 && y > 0 ? cb[o - width - 1] : rW;
          // Truncate to signed 32 bits at each Java-`int` step (see
          // [prediction]'s case-3 comment) -- cross-channel properties are
          // the default/common encoding choice for color images, so this
          // path is very likely exercised for any RGB content, not an
          // edge case.
          final int rG = (rC - _clampBetween((rW + rN - rNW).toSigned(32), rN, rW)).toSigned(32);
          if (k2++ == k) {
            return rG.abs();
          }
          if (k2++ == k) {
            return rG;
          }
        }
        return 0;
    }
  }

  /// Decodes the available JPEG XL data.
  void decode(
    BitReader reader,
    EntropyStream stream,
    WeightedPredictorParameters? weightedPredictorParameters,
    MetaAdaptiveTree tree,
    List<ModularChannel> parentChannels,
    int channelIndex,
    int streamIndex,
    int distanceMultiplier,
  ) {
    if (decoded) {
      throw StateError('channel decoded twice');
    }
    decoded = true;
    allocate();
    final bool useWp = forceWeightedPredictor || tree.usesWeightedPredictor;
    if (useWp) {
      final int n = height * width;
      _predictionError0 = Int32List(n);
      _predictionError1 = Int32List(n);
      _predictionError2 = Int32List(n);
      _predictionError3 = Int32List(n);
      _weightedPredictionError = Int32List(n);
      _weightedPrediction = Int64List(n);
    }
    final WeightedPredictorParameters? wp = useWp ? weightedPredictorParameters : null;
    final Int32List b = buffer!;
    for (var y = 0; y < height; y++) {
      final MetaAdaptiveTree refinedTree = tree.resolveStaticProperties(channelIndex, streamIndex, y);
      for (var x = 0; x < width; x++) {
        final int maxError = wp == null ? 0 : (y > 1 && x > 1 && x + 1 < width ? _prepareInteriorWeightedPrediction(wp, x, y) : _prepareWeightedPrediction(wp, x, y));
        var node = refinedTree;
        while (!node.isLeaf) {
          final int p = _property(parentChannels, channelIndex, streamIndex, node.property, maxError, y, x);
          node = p > node.value ? node.left! : node.right!;
        }
        final int diff = stream.readSymbol(reader, node.context, distanceMultiplier: distanceMultiplier);
        // Truncate to signed 32 bits at each Java-`int` assignment point
        // (see [prediction]'s case-3 comment) -- this is *the* per-pixel
        // decode hot path, run unconditionally for every pixel, so an
        // untruncated `trueValue` here doesn't just corrupt one pixel, it
        // feeds the WP error state (_predictionError0-4 below) that every *later*
        // pixel's context selection depends on, silently desyncing the
        // whole entropy stream for wide-range content (e.g. float samples
        // reinterpreted as packed 32-bit integers, see
        // ImageBuffer.reconstructFloatSamples).
        final int diff2 = (unpackSigned(diff) * node.multiplier + node.offset).toSigned(32);
        final int trueValue = (diff2 + prediction(y, x, node.predictor)).toSigned(32);
        final int o = y * width + x;
        b[o] = trueValue;
        if (useWp) {
          // NOT truncated to 32 bits: libjxl's `AddBits` (context_predict.h)
          // shifts the already-narrow stored pixel value left by
          // kPredExtraBits within `pixel_type_w` (int64_t), with no
          // intermediate narrowing before `UpdateErrors`'s own per-array
          // assignment (`pred_errors`/`error`, matched by _predictionError0-4 being
          // Int32List below -- storing into a typed list truncates on
          // write, exactly mirroring that assignment).
          final int tv3 = trueValue << 3;
          _predictionError0![o] = wideShrSigned((_predictorCandidates[0] - tv3).abs() + 3, 3);
          _predictionError1![o] = wideShrSigned((_predictorCandidates[1] - tv3).abs() + 3, 3);
          _predictionError2![o] = wideShrSigned((_predictorCandidates[2] - tv3).abs() + 3, 3);
          _predictionError3![o] = wideShrSigned((_predictorCandidates[3] - tv3).abs() + 3, 3);
          _weightedPredictionError![o] = _weightedPrediction![o] - tv3;
        }
      }
    }
    // Free the error planes, but keep pred: the delta-palette transform
    // (deltaPredictor == 6) reads prediction(y, x, 6) after decoding.
    _predictionError0 = _predictionError1 = _predictionError2 = _predictionError3 = _weightedPredictionError = null;
  }

  /// Inverse horizontal squeeze: interleaves `orig` (averages) and `res`
  /// (residues) into `channel`.
  static ModularChannel inverseHorizontalSqueeze(ModularChannel channel, ModularChannel orig, ModularChannel res) {
    if (channel.width != orig.width + res.width || orig.width != res.width && orig.width != 1 + res.width || channel.height != orig.height || res.height != orig.height) {
      throw const JpegXlInvalidBitstreamException(message: 'corrupted squeeze transform');
    }
    channel.allocate();
    final Int32List cb = channel.buffer!;
    final Int32List ob = orig.buffer!;
    final Int32List rb = res.buffer!;
    for (var y = 0; y < channel.height; y++) {
      final int oRow = y * orig.width;
      final int rRow = y * res.width;
      final int cRow = y * channel.width;
      for (var x = 0; x < res.width; x++) {
        final int avg = ob[oRow + x];
        final int residu = rb[rRow + x];
        final int nextAvg = x + 1 < orig.width ? ob[oRow + x + 1] : avg;
        final int left = x > 0 ? cb[cRow + 2 * x - 1] : avg;
        final int diff = residu + tendency(left, avg, nextAvg);
        final int first = avg + diff ~/ 2;
        cb[cRow + 2 * x] = first;
        cb[cRow + 2 * x + 1] = first - diff;
      }
    }
    if (orig.width > res.width) {
      final int xs = 2 * res.width;
      for (var y = 0; y < channel.height; y++) {
        cb[y * channel.width + xs] = ob[y * orig.width + res.width];
      }
    }
    return channel;
  }

  /// Returns the sample two columns west using the border fallback.
  @pragma('vm:prefer-inline')
  int _westWest(Int32List b, int o, int x, int y) => x > 1 ? b[o - 2] : _west(b, o, x, y);
}
