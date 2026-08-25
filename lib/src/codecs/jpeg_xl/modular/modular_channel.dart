import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl_limits.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/ma_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/wp_params.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Processes the one l24 over kp1 data used by the JPEG XL codec.
///
final Int32List _oneL24OverKP1 = () {
  final table = Int32List(64);
  for (var i = 0; i < 64; i++) {
    table[i] = (1 << 24) ~/ (i + 1);
  }
  return table;
}();

@pragma('vm:prefer-inline')
/// Clamps 3.
///
int _clamp3(int v, int a, int b) {
  final lower = a < b ? a : b;
  // max(a, b) via a plain comparison, not `lower ^ a ^ b`: a, b are
  // channel sample values, which can be negative (e.g. RCT chroma
  // channels) - dart2js's `^` reinterprets a negative operand as its
  // unsigned-32-bit equivalent and never converts the result back, so a
  // max that should come out negative comes out as a huge positive
  // number there instead.
  final upper = a < b ? b : a;
  return v < lower
      ? lower
      : v > upper
      ? upper
      : v;
}

/// Whether the WP prediction should be clamped to the (w, n, ne) range:
/// true when `tN` and `tW` don't have strictly opposite nonzero signs, and
/// likewise for `tN`/`tNW` - i.e. the gradients agree closely enough that
/// clamping to the neighborhood is safe. Originally `((tN ^ tW) | (tN ^
/// tNW)) <= 0`, a classic "XOR two ints, negative iff their signs differ"
/// trick - but `tN`/`tW`/`tNW` are WP error terms that can be negative,
/// and dart2js's `^`/`|` reinterpret a negative operand as its
/// unsigned-32-bit equivalent (and never convert the result back), so a
/// result that should come out negative comes out as a huge positive
/// number there instead, silently flipping this condition. Expressed via
/// plain sign/equality comparisons instead, which dart2js evaluates
/// correctly regardless of sign.
@pragma('vm:prefer-inline')
bool _wpShouldClamp(int tN, int tW, int tNW) => (tN < 0) != (tW < 0) || (tN < 0) != (tNW < 0) || (tN == tW && tN == tNW);

@pragma('vm:prefer-inline')
/// Clamps 4.
///
int _clamp4(int v, int a, int b, int c) {
  var lower = a < b ? a : b;
  var upper = a < b ? b : a;
  lower = lower < c ? lower : c;
  upper = upper > c ? upper : c;
  return v < lower
      ? lower
      : v > upper
      ? upper
      : v;
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
  Int32List? _err3;

  /// Stores the height value used while processing JPEG XL data.
  ///
  int height;

  /// Stores the width value used while processing JPEG XL data.
  ///
  int width;

  /// Stores the vshift value used while processing JPEG XL data.
  ///
  int vshift;

  /// Stores the hshift value used while processing JPEG XL data.
  ///
  int hshift;

  /// Stores the origin x value used while processing JPEG XL data.
  ///
  int originX = 0;

  /// Stores the origin y value used while processing JPEG XL data.
  ///
  int originY = 0;

  /// Stores the force wp value used while processing JPEG XL data.
  ///
  bool forceWp;

  /// Stores the decoded value used while processing JPEG XL data.
  ///
  bool decoded = false;

  /// Flat pixel buffer, row stride == [width].
  Int32List? buffer;

  // Weighted-predictor state, live only during decode(). _err0-4 mirror
  // libjxl's `pred_errors`/`error` (uint32_t/int32_t, narrow -- summed and
  // re-masked or re-truncated by their readers, see _wpPlaneWeight and the
  // main decode loop's `_err4` write). _pred/_subpred mirror libjxl's
  // `pred`/`prediction[]` (`pixel_type_w`, i.e. int64_t): NOT narrowed
  // until they're finally combined into a stored (int32) pixel value, so
  // these must stay wide.
  /// Stores the first weighted-predictor error row.
  Int32List? _err0;

  /// Stores the second weighted-predictor error row.
  Int32List? _err1;

  /// Stores the third weighted-predictor error row.
  Int32List? _err2;

  /// Stores the current weighted-predictor error row.
  Int32List? _err4;

  /// Stores the pred state used internally by the JPEG XL codec.
  ///
  Int64List? _pred;

  /// Processes the subpred data used by the JPEG XL codec.
  ///
  final Int64List _subpred = Int64List(4);

  /// Creates Modular channel data for JPEG XL processing.
  ///
  ModularChannel({
    required this.height,
    required this.width,
    required this.vshift,
    required this.hshift,
    this.forceWp = false,
  });

  /// Processes copy information in a JPEG XL codestream.
  ///
  ModularChannel.copy({
    required ModularChannel other,
  }) : height = other.height,
       width = other.width,
       vshift = other.vshift,
       hshift = other.hshift,
       forceWp = other.forceWp,
       originX = other.originX,
       originY = other.originY,
       decoded = other.decoded {
    if (other.buffer != null) {
      buffer = Int32List.fromList(other.buffer!);
    }
  }

  /// Processes allocate information in a JPEG XL codestream.
  ///
  void allocate() {
    if (height < 0 || width < 0 || (width != 0 && height > JpegXlLimits.maxPlanePixels ~/ width)) {
      throw JpegXlInvalidBitstreamException(message: 'channel ${width}x$height exceeds JpegXlLimits.maxPlanePixels');
    }
    buffer ??= Int32List(height * width);
  }

  /// Processes get information in a JPEG XL codestream.
  ///
  @pragma('vm:prefer-inline')
  int get(int y, int x) => buffer![y * width + x];

  /// Processes set information in a JPEG XL codestream.
  ///
  void set(int y, int x, int value) => buffer![y * width + x] = value;

  /// Processes size equals information in a JPEG XL codestream.
  ///
  bool sizeEquals(ModularChannel other) => height == other.height && width == other.width;

  // Neighbor accessors with the spec's border fallbacks. o == y * width + x.
  @pragma('vm:prefer-inline')
  /// Processes the west data used by the JPEG XL codec.
  ///
  int _west(Int32List b, int o, int x, int y) => x > 0
      ? b[o - 1]
      : y > 0
      ? b[o - width]
      : 0;

  @pragma('vm:prefer-inline')
  /// Processes the north data used by the JPEG XL codec.
  ///
  int _north(Int32List b, int o, int x, int y) => y > 0
      ? b[o - width]
      : x > 0
      ? b[o - 1]
      : 0;

  @pragma('vm:prefer-inline')
  /// Processes the north west data used by the JPEG XL codec.
  ///
  int _northWest(Int32List b, int o, int x, int y) => x > 0 ? (y > 0 ? b[o - width - 1] : b[o - 1]) : (y > 0 ? b[o - width] : 0);

  @pragma('vm:prefer-inline')
  /// Processes the north east data used by the JPEG XL codec.
  ///
  int _northEast(Int32List b, int o, int x, int y) => x + 1 < width && y > 0 ? b[o - width + 1] : _north(b, o, x, y);

  @pragma('vm:prefer-inline')
  /// Processes the north north data used by the JPEG XL codec.
  ///
  int _northNorth(Int32List b, int o, int x, int y) => y > 1 ? b[o - 2 * width] : _north(b, o, x, y);

  @pragma('vm:prefer-inline')
  /// Processes the north east east data used by the JPEG XL codec.
  ///
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

  @pragma('vm:prefer-inline')
  /// Processes the err west data used by the JPEG XL codec.
  ///
  int _errWest(Int32List e, int o, int x) => x > 0 ? e[o - 1] : 0;

  @pragma('vm:prefer-inline')
  /// Processes the err north data used by the JPEG XL codec.
  ///
  int _errNorth(Int32List e, int o, int y) => y > 0 ? e[o - width] : 0;

  @pragma('vm:prefer-inline')
  /// Processes the err west west data used by the JPEG XL codec.
  ///
  int _errWestWest(Int32List e, int o, int x) => x > 1 ? e[o - 2] : 0;

  @pragma('vm:prefer-inline')
  /// Processes the err north west data used by the JPEG XL codec.
  ///
  int _errNorthWest(Int32List e, int o, int x, int y) => x > 0 && y > 0 ? e[o - width - 1] : _errNorth(e, o, y);

  @pragma('vm:prefer-inline')
  /// Processes the err north east data used by the JPEG XL codec.
  ///
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
        return _clamp3(v, n, w);
      case 6:
        return wideShrSigned(_pred![o] + 3, 3);
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

  @pragma('vm:prefer-inline')
  /// Processes the wp plane weight data used by the JPEG XL codec.
  ///
  int _wpPlaneWeight(Int32List ep, int o, int x, int y, int wpWeight) {
    int eSum = _errNorth(ep, o, y) + _errWest(ep, o, x) + _errNorthWest(ep, o, x, y) + _errWestWest(ep, o, x) + _errNorthEast(ep, o, x, y);
    if (x + 1 == width) {
      eSum += _errWest(ep, o, x);
    }
    // jxlatte masks to unsigned 32 bits here (`eSum &= 0xffffffffL`) before
    // its `>>>` shifts below — normally a no-op for ordinary 8-16-bit
    // samples, whose summed errors never reach 32 bits, but load-bearing
    // for wide-range content (e.g. float samples reinterpreted as packed
    // 32-bit integers, `ImageBuffer.reconstructFloatSamples`): without it,
    // a large enough real sum reads as a negative Dart int (unlike Java's
    // `int`, Dart's plain `+` doesn't truncate to 32 bits on overflow — see
    // CLAUDE.md's Java-to-Dart semantics notes) and the *un*masked `>>`
    // below stays negative, indexing `_oneL24OverKP1` out of bounds.
    eSum &= 0xFFFFFFFF;
    int shift = floorLog1p(eSum) - 5;
    if (shift < 0) {
      shift = 0;
    }
    return 4 + ((wpWeight * _oneL24OverKP1[eSum >> shift]) >> shift);
  }

  @pragma('vm:prefer-inline')
  /// Processes the wp plane weight interior data used by the JPEG XL codec.
  ///
  int _wpPlaneWeightInterior(Int32List ep, int o, int wpWeight) {
    // See _wpPlaneWeight's comment: masking to unsigned 32 bits mirrors
    // jxlatte's `eSum &= 0xffffffffL`, required for wide-range (float
    // sample) content.
    final int eSum = (ep[o - width] + ep[o - 1] + ep[o - width - 1] + ep[o - 2] + ep[o - width + 1]) & 0xFFFFFFFF;
    int shift = floorLog1p(eSum) - 5;
    if (shift < 0) {
      shift = 0;
    }
    return 4 + ((wpWeight * _oneL24OverKP1[eSum >> shift]) >> shift);
  }

  /// [_prePredictWp] for interior pixels (y > 1, 1 < x < width - 1):
  /// identical arithmetic with all border branches removed.
  int _prePredictWpInterior(WpParams wp, int x, int y) {
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
    // (wider) types. `_err0-4` (this class's narrow storage, matching
    // `pred_errors`/`error`) still narrow correctly at their own
    // assignment in [decode] -- only the *intermediate* truncation here
    // was wrong. Confirmed via direct libjxl source read.
    final int n3 = b[o - width] << 3;
    final int nw3 = b[o - width - 1] << 3;
    final int ne3 = b[o - width + 1] << 3;
    final int w3 = b[o - 1] << 3;
    final int nn3 = b[o - 2 * width] << 3;
    final Int32List e4 = _err4!;
    final int tN = e4[o - width];
    final int tW = e4[o - 1];
    final int tNE = e4[o - width + 1];
    final int tNW = e4[o - width - 1];
    _subpred[0] = w3 + ne3 - n3;
    _subpred[1] = n3 - wideShrSigned((tW + tN + tNE) * wp.param1, 5);
    _subpred[2] = w3 - wideShrSigned((tW + tN + tNW) * wp.param2, 5);
    _subpred[3] = n3 - wideShrSigned(tNW * wp.param3a + tN * wp.param3b + tNE * wp.param3c + (nn3 - n3) * wp.param3d + (nw3 - w3) * wp.param3e, 5);
    final List<int> wpw = wp.weight;
    final int rw0 = _wpPlaneWeightInterior(_err0!, o, wpw[0]);
    final int rw1 = _wpPlaneWeightInterior(_err1!, o, wpw[1]);
    final int rw2 = _wpPlaneWeightInterior(_err2!, o, wpw[2]);
    final int rw3 = _wpPlaneWeightInterior(_err3!, o, wpw[3]);
    final int logWeight = floorLog1p(rw0 + rw1 + rw2 + rw3 - 1) - 4;
    final int sw0 = rw0 >> logWeight;
    final int sw1 = rw1 >> logWeight;
    final int sw2 = rw2 >> logWeight;
    final int sw3 = rw3 >> logWeight;
    final int wSum = sw0 + sw1 + sw2 + sw3;
    int s = (wSum >> 1) - 1;
    s += _subpred[0] * sw0;
    s += _subpred[1] * sw1;
    s += _subpred[2] * sw2;
    s += _subpred[3] * sw3;
    // wideShrSigned (not `>>`): the fixed-point product s * (2^24/k)
    // routinely exceeds 2^32 for ordinary pixel values, and s can be
    // negative - a bare `>>` truncates through a 32-bit int on dart2js,
    // silently corrupting the prediction (and everything downstream
    // that depends on it via the MA tree's error-based properties).
    int pred = wideShrSigned(s * _oneL24OverKP1[wSum - 1], 24);
    if (_wpShouldClamp(tN, tW, tNW)) {
      pred = _clamp4(pred, w3, n3, ne3);
    }
    _pred![o] = pred;
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
  int _prePredictWp(WpParams wp, int x, int y) {
    final Int32List b = buffer!;
    final int o = y * width + x;
    // See _prePredictWpInterior's comment: not truncated to 32 bits --
    // libjxl computes this entirely in pixel_type_w (int64_t), narrowing
    // only at _err0-4's own storage.
    final int n3 = _north(b, o, x, y) << 3;
    final int nw3 = _northWest(b, o, x, y) << 3;
    final int ne3 = _northEast(b, o, x, y) << 3;
    final int w3 = _west(b, o, x, y) << 3;
    final int nn3 = _northNorth(b, o, x, y) << 3;
    final Int32List e4 = _err4!;
    final int tN = _errNorth(e4, o, y);
    final int tW = _errWest(e4, o, x);
    final int tNE = _errNorthEast(e4, o, x, y);
    final int tNW = _errNorthWest(e4, o, x, y);
    _subpred[0] = w3 + ne3 - n3;
    _subpred[1] = n3 - wideShrSigned((tW + tN + tNE) * wp.param1, 5);
    _subpred[2] = w3 - wideShrSigned((tW + tN + tNW) * wp.param2, 5);
    _subpred[3] = n3 - wideShrSigned(tNW * wp.param3a + tN * wp.param3b + tNE * wp.param3c + (nn3 - n3) * wp.param3d + (nw3 - w3) * wp.param3e, 5);
    final List<int> wpw = wp.weight;
    final int rw0 = _wpPlaneWeight(_err0!, o, x, y, wpw[0]);
    final int rw1 = _wpPlaneWeight(_err1!, o, x, y, wpw[1]);
    final int rw2 = _wpPlaneWeight(_err2!, o, x, y, wpw[2]);
    final int rw3 = _wpPlaneWeight(_err3!, o, x, y, wpw[3]);
    final int logWeight = floorLog1p(rw0 + rw1 + rw2 + rw3 - 1) - 4;
    final int sw0 = rw0 >> logWeight;
    final int sw1 = rw1 >> logWeight;
    final int sw2 = rw2 >> logWeight;
    final int sw3 = rw3 >> logWeight;
    final int wSum = sw0 + sw1 + sw2 + sw3;
    int s = (wSum >> 1) - 1;
    s += _subpred[0] * sw0;
    s += _subpred[1] * sw1;
    s += _subpred[2] * sw2;
    s += _subpred[3] * sw3;
    // wideShrSigned (not `>>`): the fixed-point product s * (2^24/k)
    // routinely exceeds 2^32 for ordinary pixel values, and s can be
    // negative - a bare `>>` truncates through a 32-bit int on dart2js,
    // silently corrupting the prediction (and everything downstream
    // that depends on it via the MA tree's error-based properties).
    int pred = wideShrSigned(s * _oneL24OverKP1[wSum - 1], 24);
    if (_wpShouldClamp(tN, tW, tNW)) {
      pred = _clamp4(pred, w3, n3, ne3);
    }
    _pred![o] = pred;
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
          if (!sizeEquals(channel) || vshift != channel.vshift || hshift != channel.hshift) {
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
          final int rG = (rC - _clamp3((rW + rN - rNW).toSigned(32), rN, rW)).toSigned(32);
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

  /// Processes decode information in a JPEG XL codestream.
  ///
  void decode(BitReader reader, EntropyStream stream, WpParams? wpParams, MaTree tree, List<ModularChannel> parentChannels, int channelIndex, int streamIndex, int distMultiplier) {
    if (decoded) {
      throw StateError('channel decoded twice');
    }
    decoded = true;
    allocate();
    final bool useWp = forceWp || tree.usesWeightedPredictor;
    if (useWp) {
      final int n = height * width;
      _err0 = Int32List(n);
      _err1 = Int32List(n);
      _err2 = Int32List(n);
      _err3 = Int32List(n);
      _err4 = Int32List(n);
      _pred = Int64List(n);
    }
    final WpParams? wp = useWp ? wpParams : null;
    final Int32List b = buffer!;
    for (var y = 0; y < height; y++) {
      final MaTree refinedTree = tree.compactify(channelIndex, streamIndex, y);
      for (var x = 0; x < width; x++) {
        final int maxError = wp == null ? 0 : (y > 1 && x > 1 && x + 1 < width ? _prePredictWpInterior(wp, x, y) : _prePredictWp(wp, x, y));
        var node = refinedTree;
        while (!node.isLeaf) {
          final int p = _property(parentChannels, channelIndex, streamIndex, node.property, maxError, y, x);
          node = p > node.value ? node.left! : node.right!;
        }
        final int diff = stream.readSymbol(reader, node.context, distanceMultiplier: distMultiplier);
        // Truncate to signed 32 bits at each Java-`int` assignment point
        // (see [prediction]'s case-3 comment) -- this is *the* per-pixel
        // decode hot path, run unconditionally for every pixel, so an
        // untruncated `trueValue` here doesn't just corrupt one pixel, it
        // feeds the WP error state (_err0-4 below) that every *later*
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
          // assignment (`pred_errors`/`error`, matched by _err0-4 being
          // Int32List below -- storing into a typed list truncates on
          // write, exactly mirroring that assignment).
          final int tv3 = trueValue << 3;
          _err0![o] = wideShrSigned((_subpred[0] - tv3).abs() + 3, 3);
          _err1![o] = wideShrSigned((_subpred[1] - tv3).abs() + 3, 3);
          _err2![o] = wideShrSigned((_subpred[2] - tv3).abs() + 3, 3);
          _err3![o] = wideShrSigned((_subpred[3] - tv3).abs() + 3, 3);
          _err4![o] = _pred![o] - tv3;
        }
      }
    }
    // Free the error planes, but keep pred: the delta-palette transform
    // (dPred == 6) reads prediction(y, x, 6) after decoding.
    _err0 = _err1 = _err2 = _err3 = _err4 = null;
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

  @pragma('vm:prefer-inline')
  /// Processes the west west data used by the JPEG XL codec.
  ///
  int _westWest(Int32List b, int o, int x, int y) => x > 1 ? b[o - 2] : _west(b, o, x, y);
}
