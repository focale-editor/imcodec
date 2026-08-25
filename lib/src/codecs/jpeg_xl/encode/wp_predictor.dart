import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Encoder-side self-correcting weighted predictor (predictor 6): the exact
/// forward mirror of the decoder's `_prePredictWp` state machine, run over a
/// tile in raster order to produce residuals.
///
/// The error-plane state is reset per tile, matching the decoder's per-group
/// modular channels.

// Default WpParams: (16, 10, 7, 7, 7, 0, 0, [13, 12, 12, 12]).
/// Stores the wp param1 state used internally by the JPEG XL codec.
///
const _wpParam1 = 16;

/// Stores the wp param2 state used internally by the JPEG XL codec.
///
const _wpParam2 = 10;

/// Stores the wp param3a state used internally by the JPEG XL codec.
///
const _wpParam3a = 7;

/// Stores the wp param3b state used internally by the JPEG XL codec.
///
const _wpParam3b = 7;

/// Stores the wp param3c state used internally by the JPEG XL codec.
///
const _wpParam3c = 7;

/// Stores the wp param3d state used internally by the JPEG XL codec.
///
const _wpParam3d = 0;

/// Stores the wp param3e state used internally by the JPEG XL codec.
///
const _wpParam3e = 0;

/// Stores the wp weight0 state used internally by the JPEG XL codec.
///
const _wpWeight0 = 13;

/// Stores the wp weight1 state used internally by the JPEG XL codec.
///
const _wpWeight1 = 12;

/// Stores the wp weight2 state used internally by the JPEG XL codec.
///
const _wpWeight2 = 12;

/// Stores the wp weight3 state used internally by the JPEG XL codec.
///
const _wpWeight3 = 12;

/// Processes the one l24 over kp1 data used by the JPEG XL codec.
///
final Int32List _oneL24OverKP1 = () {
  final t = Int32List(64);
  for (var i = 0; i < 64; i++) {
    t[i] = (1 << 24) ~/ (i + 1);
  }
  return t;
}();

/// Clamps 4.
///
int _clamp4(int v, int a, int b, int c) {
  var lower = a < b ? a : b;
  // max(a, b) via a plain comparison, not `lower ^ a ^ b`: a, b are
  // channel sample values, which can be negative (e.g. RCT chroma
  // channels) - dart2js's `^` reinterprets a negative operand as its
  // unsigned-32-bit equivalent and never converts the result back, so a
  // max that should come out negative comes out as a huge positive
  // number there instead.
  var upper = a < b ? b : a;
  lower = lower < c ? lower : c;
  upper = upper > c ? upper : c;
  return v < lower
      ? lower
      : v > upper
      ? upper
      : v;
}

/// Whether the WP prediction should be clamped to the (w, n, ne) range -
/// see the decoder's `_wpShouldClamp` (modular_channel.dart) for why this
/// is written via sign/equality comparisons rather than the classic
/// `((tN ^ tW) | (tN ^ tNW)) <= 0` XOR trick.
bool _wpShouldClamp(int tN, int tW, int tNW) => (tN < 0) != (tW < 0) || (tN < 0) != (tNW < 0) || (tN == tW && tN == tNW);

/// Fills [residuals] (length tw*th) with `value - weightedPrediction` for the
/// tile, in raster order. When [maxErrors] is given, also records each
/// pixel's WP max-error (decoder property 15) for context modeling.
void wpTileResiduals(Int32List tile, int tw, int th, Int32List residuals, [Int32List? maxErrors]) {
  final err0 = Int32List(tw * th);
  final err1 = Int32List(tw * th);
  final err2 = Int32List(tw * th);
  final err3 = Int32List(tw * th);
  final err4 = Int32List(tw * th);

  int north(int o, int x, int y) => y > 0
      ? tile[o - tw]
      : x > 0
      ? tile[o - 1]
      : 0;
  int west(int o, int x, int y) => x > 0
      ? tile[o - 1]
      : y > 0
      ? tile[o - tw]
      : 0;
  int northWest(int o, int x, int y) => x > 0 ? (y > 0 ? tile[o - tw - 1] : tile[o - 1]) : (y > 0 ? tile[o - tw] : 0);
  int northEast(int o, int x, int y) => x + 1 < tw && y > 0 ? tile[o - tw + 1] : north(o, x, y);
  int northNorth(int o, int x, int y) => y > 1 ? tile[o - 2 * tw] : north(o, x, y);

  int errNorth(Int32List e, int o, int y) => y > 0 ? e[o - tw] : 0;
  int errWest(Int32List e, int o, int x) => x > 0 ? e[o - 1] : 0;
  int errWestWest(Int32List e, int o, int x) => x > 1 ? e[o - 2] : 0;
  int errNorthWest(Int32List e, int o, int x, int y) => x > 0 && y > 0 ? e[o - tw - 1] : errNorth(e, o, y);
  int errNorthEast(Int32List e, int o, int x, int y) => x + 1 < tw && y > 0 ? e[o - tw + 1] : errNorth(e, o, y);

  int planeWeight(Int32List ep, int o, int x, int y, int wpWeight) {
    int eSum = errNorth(ep, o, y) + errWest(ep, o, x) + errNorthWest(ep, o, x, y) + errWestWest(ep, o, x) + errNorthEast(ep, o, x, y);
    if (x + 1 == tw) {
      eSum += errWest(ep, o, x);
    }
    int shift = floorLog1p(eSum) - 5;
    if (shift < 0) {
      shift = 0;
    }
    return 4 + ((wpWeight * _oneL24OverKP1[eSum >> shift]) >> shift);
  }

  final subpred = Int32List(4);
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      final int o = y * tw + x;
      final int n3 = north(o, x, y) << 3;
      final int nw3 = northWest(o, x, y) << 3;
      final int ne3 = northEast(o, x, y) << 3;
      final int w3 = west(o, x, y) << 3;
      final int nn3 = northNorth(o, x, y) << 3;
      final int tN = errNorth(err4, o, y);
      final int tW = errWest(err4, o, x);
      final int tNE = errNorthEast(err4, o, x, y);
      final int tNW = errNorthWest(err4, o, x, y);
      subpred[0] = w3 + ne3 - n3;
      subpred[1] = n3 - (((tW + tN + tNE) * _wpParam1) >> 5);
      subpred[2] = w3 - (((tW + tN + tNW) * _wpParam2) >> 5);
      subpred[3] = n3 - ((tNW * _wpParam3a + tN * _wpParam3b + tNE * _wpParam3c + (nn3 - n3) * _wpParam3d + (nw3 - w3) * _wpParam3e) >> 5);
      final int rw0 = planeWeight(err0, o, x, y, _wpWeight0);
      final int rw1 = planeWeight(err1, o, x, y, _wpWeight1);
      final int rw2 = planeWeight(err2, o, x, y, _wpWeight2);
      final int rw3 = planeWeight(err3, o, x, y, _wpWeight3);
      final int logWeight = floorLog1p(rw0 + rw1 + rw2 + rw3 - 1) - 4;
      final int sw0 = rw0 >> logWeight;
      final int sw1 = rw1 >> logWeight;
      final int sw2 = rw2 >> logWeight;
      final int sw3 = rw3 >> logWeight;
      final int wSum = sw0 + sw1 + sw2 + sw3;
      int s = (wSum >> 1) - 1;
      s += subpred[0] * sw0;
      s += subpred[1] * sw1;
      s += subpred[2] * sw2;
      s += subpred[3] * sw3;
      // wideShrSigned (not `>>`): the fixed-point product s * (2^24/k)
      // routinely exceeds 2^32 for ordinary pixel values, and s can be
      // negative - a bare `>>` truncates through a 32-bit int on
      // dart2js, silently corrupting the prediction.
      int pred = wideShrSigned(s * _oneL24OverKP1[wSum - 1], 24);
      if (_wpShouldClamp(tN, tW, tNW)) {
        pred = _clamp4(pred, w3, n3, ne3);
      }
      if (maxErrors != null) {
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
        maxErrors[o] = maxError;
      }
      final int trueValue = tile[o];
      residuals[o] = trueValue - ((pred + 3) >> 3);
      final int tv3 = trueValue << 3;
      err0[o] = ((subpred[0] - tv3).abs() + 3) >> 3;
      err1[o] = ((subpred[1] - tv3).abs() + 3) >> 3;
      err2[o] = ((subpred[2] - tv3).abs() + 3) >> 3;
      err3[o] = ((subpred[3] - tv3).abs() + 3) >> 3;
      err4[o] = pred - tv3;
    }
  }
}
