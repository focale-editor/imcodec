import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/weighted_prediction.dart';

/// Implements the encoder-side self-correcting weighted predictor.
/// This is the exact
/// forward mirror of the decoder's `_prepareWeightedPrediction` state machine, run over a
/// tile in raster order to produce residuals.
/// The error-plane state is reset per tile, matching the decoder's per-group
/// modular channels.

// Default WeightedPredictorParameters: (16, 10, 7, 7, 7, 0, 0, [13, 12, 12, 12]).
/// Specification constant used for weighted-predictor parameter 1.
const _wpParam1 = 16;

/// Specification constant used for weighted-predictor parameter 2.
const _wpParam2 = 10;

/// Specification constant used for weighted-predictor parameter 3a.
const _wpParam3a = 7;

/// Specification constant used for weighted-predictor parameter 3b.
const _wpParam3b = 7;

/// Specification constant used for weighted-predictor parameter 3c.
const _wpParam3c = 7;

/// Specification constant used for weighted-predictor parameter 3d.
const _wpParam3d = 0;

/// Specification constant used for weighted-predictor parameter 3e.
const _wpParam3e = 0;

/// Specification constant used for weighted-predictor weight 0.
const _wpWeight0 = 13;

/// Specification constant used for weighted-predictor weight 1.
const _wpWeight1 = 12;

/// Specification constant used for weighted-predictor weight 2.
const _wpWeight2 = 12;

/// Specification constant used for weighted-predictor weight 3.
const _wpWeight3 = 12;

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
  int errNorthWest(Int32List e, int o, int x, int y) => x > 0 && y > 0 ? e[o - tw - 1] : errNorth(e, o, y);
  int errNorthEast(Int32List e, int o, int x, int y) => x + 1 < tw && y > 0 ? e[o - tw + 1] : errNorth(e, o, y);

  int planeWeight(Int32List predictionErrors, int offset, int column, int row, int predictorWeight) => weightedPredictorPlaneWeight(
    predictionErrors: predictionErrors,
    offset: offset,
    column: column,
    row: row,
    width: tw,
    predictorWeight: predictorWeight,
  );

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
      int pred = wideShrSigned(s * weightedPredictionReciprocalTable[wSum - 1], 24);
      if (shouldClampWeightedPrediction(northError: tN, westError: tW, northWestError: tNW)) {
        pred = clampWeightedPrediction(value: pred, west: w3, north: n3, northEast: ne3);
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
