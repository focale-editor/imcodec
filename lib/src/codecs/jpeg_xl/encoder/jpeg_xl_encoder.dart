import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/encoder/context_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/encoder/entropy_encoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/encoder/header_encoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/encoder/var_dct_encoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/encoder/weighted_predictor.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/hybrid_uint.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/image.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_writer.dart';

/// Encodes JPEG XL codestreams entirely in Dart.
/// The output decodes bit-exact with any conforming decoder; every file is
/// gated in tests against both this package's decoder and libjxl's djxl.
final class JpegXlCodestreamEncoder {
  /// Losslessly encodes interleaved 8-bit pixels.
  /// [pixels] layout is `width * height * channelCount` bytes where the
  /// channel count is 1 (gray), 2 (gray+alpha), 3 (RGB) or 4 (RGBA)
  /// according to [grayscale] and [hasAlpha].
  static Uint8List encodeLossless(Uint8List pixels, {required int width, required int height, bool grayscale = false, bool hasAlpha = false}) {
    final setup = JpegXlEncodeSetup(width: width, height: height, bitsPerSample: 8, grayscale: grayscale, hasAlpha: hasAlpha);
    final int n = setup.channelCount;
    if (pixels.length != width * height * n) {
      throw ArgumentError(
        'expected ${width * height * n} bytes, '
        'got ${pixels.length}',
      );
    }
    final List<Int32List> planes = [for (var c = 0; c < n; c++) Int32List(width * height)];
    for (var c = 0; c < n; c++) {
      final Int32List plane = planes[c];
      for (var i = 0; i < width * height; i++) {
        plane[i] = pixels[i * n + c];
      }
    }
    return _encodeModular(setup, planes);
  }

  /// Losslessly encodes interleaved 16-bit pixels (same layout as
  /// [encodeLossless]).
  static Uint8List encodeLossless16(Uint16List pixels, {required int width, required int height, bool grayscale = false, bool hasAlpha = false}) {
    final setup = JpegXlEncodeSetup(width: width, height: height, bitsPerSample: 16, grayscale: grayscale, hasAlpha: hasAlpha);
    final int n = setup.channelCount;
    if (pixels.length != width * height * n) {
      throw ArgumentError(
        'expected ${width * height * n} samples, '
        'got ${pixels.length}',
      );
    }
    final List<Int32List> planes = [for (var c = 0; c < n; c++) Int32List(width * height)];
    for (var c = 0; c < n; c++) {
      final Int32List plane = planes[c];
      for (var i = 0; i < width * height; i++) {
        plane[i] = pixels[i * n + c];
      }
    }
    return _encodeModular(setup, planes);
  }

  /// Losslessly re-encodes a decoded [JpegXlDecodedImage] (integer samples only).
  static Uint8List encodeImage(JpegXlDecodedImage image) {
    final ImageHeader header = image.header;
    if (header.bitDepth.usesFloatSamples || image.channels[0].isFloat) {
      throw ArgumentError('only integer images can be re-encoded losslessly');
    }
    final setup = JpegXlEncodeSetup(width: image.width, height: image.height, bitsPerSample: header.bitDepth.bitsPerSample, grayscale: header.isGrayscale, hasAlpha: image.hasAlpha);
    final int channels = setup.channelCount;
    final planes = <Int32List>[];
    final int maxValue = header.bitDepth.maxValue;
    for (var c = 0; c < channels; c++) {
      final List<Int32List> rows = image.channels[c].intRows;
      final plane = Int32List(setup.width * setup.height);
      for (var y = 0; y < setup.height; y++) {
        final Int32List row = rows[y];
        for (var x = 0; x < setup.width; x++) {
          final int v = row[x];
          plane[y * setup.width + x] = v < 0
              ? 0
              : v > maxValue
              ? maxValue
              : v;
        }
      }
      planes.add(plane);
    }
    return _encodeModular(setup, planes);
  }

  /// Lossily (VarDCT) encodes an interleaved 8-bit RGB image
  /// (doc/lossy_encoder_plan.md's L0-L3 plus per-region chroma-from-luma:
  /// real HF coefficient context model, multi-group, multi-LF-group,
  /// adaptive quantization; filters and variable transform size are
  /// opt-in via [config], off by default). [width] and [height] must be
  /// multiples of 8. [distance] is a cjxl-like quality knob (larger =
  /// smaller/lower quality); pass [config] instead for direct control
  /// over the quantizer knobs.
  static Uint8List encodeLossy(Uint8List rgbPixels, {required int width, required int height, double distance = 1.0, VarDctConfiguration? config}) => encodeLossyVarDct(
    rgbPixels,
    width: width,
    height: height,
    config: config ?? VarDctConfiguration.fromDistance(distance: distance),
  );
}

/// The default hybrid-uint tokenization config, also used to train the
/// context tree (the tree's split ranking is insensitive to which candidate
/// config below is ultimately chosen — verified: fixing tree training here
/// while sweeping the entropy config gives byte-identical output).
const _config = HybridIntegerConfig(splitExponent: 4, msbInToken: 1, lsbInToken: 0);

/// Candidate hybrid-uint configs tried per image at the entropy-coding stage;
/// the smallest actual output wins (like the predictor / entropy-mode choice).
/// The config only changes how residuals at/above the split point (2^4 packed,
/// i.e. |residual| >= 8) are tokenized — it's a no-op for small-residual
/// content, so trying `(4, 2, 0)` is free there and a real win where it
/// helps (screentone/manga -2% to -4%, some gradients/photos a fraction of a
/// percent; `(4, 1, 0)` still wins on smooth-photo and palette content, hence
/// keeping both and choosing per image). Both are decoder-legal and the
/// chosen config is serialized into each entropy stream's header.
const _hybridConfigs = [HybridIntegerConfig(splitExponent: 4, msbInToken: 1, lsbInToken: 0), HybridIntegerConfig(splitExponent: 4, msbInToken: 2, lsbInToken: 0)];

/// Packs signed.
int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

/// Pass A over a tile: appends packed-signed residuals (clamped-gradient, or
/// the weighted predictor when [useWp]) to [valuesOut], and for every
/// [stride]-th pixel records its property vector and hybrid token for
/// context-tree training.
void _tileResiduals(
  Int32List plane,
  int imageWidth,
  int ox,
  int oy,
  int tw,
  int th,
  List<int> valuesOut,
  List<int>? maxErrOut,
  List<int> trainProps,
  List<int> trainTokens,
  int stride,
  List<int> strideState,
  bool useWp,
  List<int> properties, {
  int channelIndex = 0,
  Int32List? priorPlane,
}) {
  final tile = Int32List(tw * th);
  for (var y = 0; y < th; y++) {
    tile.setRange(y * tw, y * tw + tw, plane, (oy + y) * imageWidth + ox);
  }
  Int32List? priorTile;
  if (priorPlane != null) {
    priorTile = Int32List(tw * th);
    for (var y = 0; y < th; y++) {
      priorTile.setRange(y * tw, y * tw + tw, priorPlane, (oy + y) * imageWidth + ox);
    }
  }
  Int32List? wpRes;
  Int32List? wpErr;
  if (useWp) {
    wpRes = Int32List(tw * th);
    wpErr = Int32List(tw * th);
    wpTileResiduals(tile, tw, th, wpRes, wpErr);
  }
  final props = Int32List(properties.length);
  int counter = strideState[0];
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      final int o = y * tw + x;
      final int value;
      if (useWp) {
        value = _packSigned(wpRes![o]);
        maxErrOut!.add(wpErr![o]);
      } else {
        final int w = x > 0
            ? tile[o - 1]
            : y > 0
            ? tile[o - tw]
            : 0;
        final int n = y > 0 ? tile[o - tw] : w;
        final int nw = x > 0 && y > 0 ? tile[o - tw - 1] : w;
        final int grad = w + n - nw;
        final lo = w < n ? w : n;
        final hi = w > n ? w : n;
        final pred = grad < lo
            ? lo
            : grad > hi
            ? hi
            : grad;
        value = _packSigned(tile[o] - pred);
      }
      valuesOut.add(value);
      if (counter == 0) {
        computeProps(tile, tw, th, y, x, properties, wpErr?[o] ?? 0, props, channelIndex: channelIndex, prior: priorTile);
        for (var pi = 0; pi < props.length; pi++) {
          trainProps.add(props[pi]);
        }
        trainTokens.add(tokenizeHybrid(_config, value).$1);
        counter = stride;
      }
      counter--;
    }
  }
  strideState[0] = counter;
}

/// Pass B over a tile: assigns each pixel a context by walking [tree]. The
/// per-pixel max-error (property 15) is read from [maxErrIn] (filled by Pass
/// A in the same order) so the weighted predictor isn't recomputed.
void _tileContexts(Int32List plane, int imageWidth, int ox, int oy, int tw, int th, ContextTree tree, List<int> contextsOut, List<int>? maxErrIn, {int channelIndex = 0, Int32List? priorPlane}) {
  final tile = Int32List(tw * th);
  for (var y = 0; y < th; y++) {
    tile.setRange(y * tw, y * tw + tw, plane, (oy + y) * imageWidth + ox);
  }
  Int32List? priorTile;
  if (priorPlane != null) {
    priorTile = Int32List(tw * th);
    for (var y = 0; y < th; y++) {
      priorTile.setRange(y * tw, y * tw + tw, priorPlane, (oy + y) * imageWidth + ox);
    }
  }
  final props = Int32List(tree.properties.length);
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      final int me = maxErrIn != null ? maxErrIn[contextsOut.length] : 0;
      computeProps(tile, tw, th, y, x, tree.properties, me, props, channelIndex: channelIndex, prior: priorTile);
      contextsOut.add(contextFor(tree, props));
    }
  }
}

/// Forward YCoCg (RCT type 6): the exact integer mirror of the decoder's
/// inverse.
void _forwardRct(List<Int32List> planes) {
  final Int32List p0 = planes[0];
  final Int32List p1 = planes[1];
  final Int32List p2 = planes[2];
  for (var i = 0; i < p0.length; i++) {
    final int o0 = p0[i];
    final int o1 = p1[i];
    final int o2 = p2[i];
    final int s1 = o0 - o2;
    final int tmp = o2 + (s1 >> 1);
    final int s2 = o1 - tmp;
    p0[i] = tmp + (s2 >> 1);
    p1[i] = s1;
    p2[i] = s2;
  }
}

/// Collects the distinct colors of the first three [planes]; null when
/// more than [maxColors].
List<int>? _detectPalette(List<Int32List> planes, int maxColors) {
  final seen = <int>{};
  final Int32List p0 = planes[0];
  final Int32List p1 = planes[1];
  final Int32List p2 = planes[2];
  for (var i = 0; i < p0.length; i++) {
    seen.add((p0[i] << 40) | (p1[i] << 20) | p2[i]);
    if (seen.length > maxColors) {
      return null;
    }
  }
  final List<int> colors = seen.toList()
    ..sort((a, b) {
      int lum(int k) => (k >>> 40) + ((k >>> 20) & 0xFFFFF) + (k & 0xFFFFF);
      return lum(a) - lum(b);
    });
  return colors;
}

/// Single-channel (grayscale) palette detection: the distinct sample values,
/// sorted, or null past [maxColors]. A grayscale palette remaps a small, often
/// *sparse* set of sample values (e.g. bilevel line art / fractals at {0,255})
/// to a dense 0..k-1 index channel, whose gradient residuals are ±1 tokens
/// instead of ±255 — a large win on few-colour grayscale that the RGB
/// [_detectPalette] never reaches (grayscale historically skipped palette
/// entirely). The caller keeps whichever of palette/plain codes smaller.
List<int>? _detectPaletteGray(Int32List plane, int maxColors) {
  final seen = <int>{};
  for (var i = 0; i < plane.length; i++) {
    seen.add(plane[i]);
    if (seen.length > maxColors) {
      return null;
    }
  }
  return seen.toList()..sort();
}

/// Minimum relative gap in learned-tree training entropy for one predictor to
/// be declared the clear winner (so the loser's Pass B + entropy coding +
/// assembly is skipped). 2% is comfortably above the strided training set's
/// own sampling noise (~0.2% for the ~300k-sample cap), so a gap this large
/// reflects a real difference, not noise; smaller gaps fall through to the
/// "finish both, keep smaller" path. Empirically, every corpus/photographic
/// image with a gap ≥ this picked the same predictor its full-pipeline byte
/// count did.
const _kPredictorMargin = 1.02;

/// Everything Pass A + tree learning produces for one predictor, kept around so
/// the two predictors' trees can be compared cheaply (via
/// [ContextTree.trainingBits]) before the expensive Pass B + entropy coding,
/// and so the loser's per-pixel residuals stay available for per-leaf predictor
/// selection (the winning tree's leaves may switch to the loser's predictor).
typedef _Prep = ({int predictor, List<int> properties, ContextTree tree, List<List<int>> groupValues, List<List<int>>? groupMaxErr, List<int> metaValues, List<int>? metaMaxErr});

/// Pass B output for one prep: the per-region leaf contexts (reused to build
/// the mixed value stream) plus the same contexts already grouped into
/// entropy-coding sections.
typedef _PassB = ({List<int> metaContexts, List<List<int>> groupContexts, List<List<int>> sectionContexts});

/// Estimates the zero-order entropy of one slice of [histogram].
double _histogramEntropy(Int32List histogram, int offset, int width, int total) {
  if (total == 0) {
    return 0;
  }
  double bitCount = 0;
  final double sampleCount = total.toDouble();
  for (var token = 0; token < width; token++) {
    final int frequency = histogram[offset + token];
    if (frequency > 0) {
      bitCount += frequency * (math.log(sampleCount / frequency) * 1.4426950408889634);
    }
  }
  return bitCount;
}

/// Chooses, per tree leaf, whether to keep [primaryPredictor]'s residuals or
/// switch to [altPredictor]'s — whichever tokenises that leaf's own pixels to
/// fewer bits (zeroth-order token entropy over the leaf's histogram, plus the
/// hybrid-uint extra bits, mirroring [ContextTree.trainingBits]). This only
/// constructs a candidate; the caller assembles both the mixed and the
/// single-predictor streams and keeps the smaller actual bytes, so a per-leaf
/// misprediction never regresses size. [primaryValues]/[altValues] are the two
/// predictors' packed-signed residuals, aligned index-for-index with the
/// contexts (same Pass A iteration order).
List<int> _selectLeafPredictors(
  int contextCount,
  int primaryPredictor,
  int altPredictor,
  List<int> metaContexts,
  List<List<int>> groupContexts,
  List<int> primaryMeta,
  List<List<int>> primaryGroups,
  List<int> altMeta,
  List<List<int>> altGroups,
) {
  var maxTok = 0;
  void scan(int v) {
    final int t = tokenizeHybrid(_config, v).$1;
    if (t > maxTok) {
      maxTok = t;
    }
  }

  for (var i = 0; i < primaryMeta.length; i++) {
    scan(primaryMeta[i]);
    scan(altMeta[i]);
  }
  for (var g = 0; g < primaryGroups.length; g++) {
    final List<int> pg = primaryGroups[g];
    final List<int> ag = altGroups[g];
    for (var i = 0; i < pg.length; i++) {
      scan(pg[i]);
      scan(ag[i]);
    }
  }

  final int w = maxTok + 1;
  final pHist = Int32List(contextCount * w);
  final aHist = Int32List(contextCount * w);
  final pExtra = Float64List(contextCount);
  final aExtra = Float64List(contextCount);
  final counts = Int32List(contextCount);

  void acc(int c, int pv, int av) {
    final (int pt, int pn, _) = tokenizeHybrid(_config, pv);
    final (int at, int an, _) = tokenizeHybrid(_config, av);
    pHist[c * w + pt]++;
    aHist[c * w + at]++;
    pExtra[c] += pn;
    aExtra[c] += an;
    counts[c]++;
  }

  for (var i = 0; i < metaContexts.length; i++) {
    acc(metaContexts[i], primaryMeta[i], altMeta[i]);
  }
  for (var g = 0; g < groupContexts.length; g++) {
    final List<int> gc = groupContexts[g];
    final List<int> pg = primaryGroups[g];
    final List<int> ag = altGroups[g];
    for (var i = 0; i < gc.length; i++) {
      acc(gc[i], pg[i], ag[i]);
    }
  }

  final leafPred = List<int>.filled(contextCount, primaryPredictor);
  for (var c = 0; c < contextCount; c++) {
    final int total = counts[c];
    if (total == 0) {
      continue;
    }
    final double pBits = _histogramEntropy(pHist, c * w, w, total) + pExtra[c];
    final double aBits = _histogramEntropy(aHist, c * w, w, total) + aExtra[c];
    // Strict improvement only, so a numerical tie keeps the primary predictor
    // (and thus stays byte-identical to the single-predictor baseline).
    if (aBits < pBits) {
      leafPred[c] = altPredictor;
    }
  }
  return leafPred;
}

/// Builds the per-pixel residual stream for a per-leaf predictor assignment:
/// each pixel emits [primary]'s residual when its leaf kept [primaryPredictor],
/// else [alt]'s. All three lists are aligned index-for-index.
List<int> _mixValues(List<int> contexts, List<int> primary, List<int> alt, List<int> leafPred, int primaryPredictor) {
  final out = List<int>.filled(contexts.length, 0);
  for (var i = 0; i < contexts.length; i++) {
    out[i] = leafPred[contexts[i]] == primaryPredictor ? primary[i] : alt[i];
  }
  return out;
}

/// Colour-count cap for even *attempting* the palette transform. Palette wins
/// on flat/few-colour graphics (UI screenshots, line art) but loses on
/// photographic content, and a hard threshold picks wrong on both sides — so
/// [_encodeModular] tries palette *and* non-palette below this cap and keeps
/// the smaller (never-worse). The cap only bounds the 2x cost to genuinely
/// low-colour images; it is not a correctness knob (RCT is always tried).
const _kPaletteMaxColors = 4096;

/// Distinct-value cap for grayscale palette *detection*. Bounds the hash-set
/// and palette meta-channel cost; 8-bit grayscale never exceeds 256 distinct
/// values anyway, so this only bites pathological high-bit-depth input. The
/// *decision* to spend a second encode is the sparsity gate below, not this cap.
const _kPaletteMaxColorsGray = 256;

/// A grayscale palette earns its second full encode only when the value set is
/// **sparse** — many gaps in `[min, max]` — because the transform's whole win is
/// remapping those sparse values to a dense `0..k-1` index whose gradient
/// residuals are small (±1 on bilevel line art, versus ±255 raw). Dense
/// grayscale — photographs using nearly all 256 tones — gains almost nothing
/// from the remap and would only pay ~2x encode time, so it is skipped here (the
/// palette is still only *kept* when it codes smaller, so this bounds cost, not
/// correctness). The 0.8 density cut sits in the wide empirical gap between the
/// sparse winners (≤0.69 on the burkardt grayscale set: fractals, line art, the
/// `move*` graphics) and dense photos (≥0.88). See doc/BENCHMARKS.md.
bool _grayPaletteWorthTrying(List<int> colors) {
  final int span = colors.last - colors.first + 1;
  return colors.length < 0.8 * span;
}

/// Copies planes.
List<Int32List> _copyPlanes(List<Int32List> planes) => [for (final p in planes) Int32List.fromList(p)];

/// Color modular encode: try the RCT (non-palette) path always, and the palette
/// path when the colour count is small enough, keeping whichever is smaller.
/// Grayscale tries a single-channel palette under the same never-worse rule when
/// its value set is sparse enough to benefit (see [_grayPaletteWorthTrying]).
Uint8List _encodeModular(JpegXlEncodeSetup setup, List<Int32List> planes) {
  if (setup.grayscale) {
    final Uint8List grayBytes = _encodeModularCore(setup, planes, null, false);
    final List<int>? palette = _detectPaletteGray(planes[0], _kPaletteMaxColorsGray);
    if (palette == null || !_grayPaletteWorthTrying(palette)) {
      return grayBytes;
    }
    final Uint8List palBytes = _encodeModularCore(setup, _copyPlanes(planes), palette, false, paletteChannels: 1);
    return palBytes.length < grayBytes.length ? palBytes : grayBytes;
  }
  final List<int>? palette = _detectPalette(planes, _kPaletteMaxColors);
  final Uint8List rctBytes = _encodeModularCore(setup, _copyPlanes(planes), null, true);
  if (palette == null) {
    return rctBytes;
  }
  final Uint8List palBytes = _encodeModularCore(setup, _copyPlanes(planes), palette, false);
  return palBytes.length < rctBytes.length ? palBytes : rctBytes;
}

/// Encodes modular core.
Uint8List _encodeModularCore(JpegXlEncodeSetup setup, List<Int32List> inputPlanes, List<int>? palette, bool applyRct, {int paletteChannels = 3}) {
  List<Int32List> planes = inputPlanes;
  const groupDimension = 256;
  final int width = setup.width;
  final int height = setup.height;
  final int groupsX = ceilDiv(width, groupDimension);
  final int groupsY = ceilDiv(height, groupDimension);
  final int groupCount = groupsX * groupsY;
  final int lowFrequencyGroupCount = ceilDiv(width, groupDimension << 3) * ceilDiv(height, groupDimension << 3);
  final singleSection = groupCount == 1;
  final bool globalChannels = width <= groupDimension && height <= groupDimension;

  // Transform application (the palette-vs-RCT *decision* is [_encodeModular]'s;
  // here it is a given). Palette: replace the 3 colour planes with one index
  // channel. RCT: in-place colour decorrelation.
  final useRct = applyRct;
  if (palette != null) {
    final lookup = <int, int>{};
    for (var i = 0; i < palette.length; i++) {
      lookup[palette[i]] = i;
    }
    final Int32List p0 = planes[0];
    final index = Int32List(p0.length);
    if (paletteChannels == 1) {
      for (var i = 0; i < p0.length; i++) {
        index[i] = lookup[p0[i]]!;
      }
    } else {
      final Int32List p1 = planes[1];
      final Int32List p2 = planes[2];
      for (var i = 0; i < p0.length; i++) {
        index[i] = lookup[(p0[i] << 40) | (p1[i] << 20) | p2[i]]!;
      }
    }
    planes = [index, ...planes.sublist(paletteChannels)];
  } else if (applyRct) {
    _forwardRct(planes);
  }

  // The palette meta channel (its colors) is predictor-independent.
  final int totalPixels = width * height * planes.length;
  final int stride = totalPixels > 300000 ? totalPixels ~/ 300000 : 1;
  Int32List? pal;
  if (palette != null) {
    final int n = palette.length;
    if (paletteChannels == 1) {
      pal = Int32List(n);
      for (var i = 0; i < n; i++) {
        pal[i] = palette[i];
      }
    } else {
      pal = Int32List(3 * n);
      for (var i = 0; i < n; i++) {
        pal[i] = palette[i] >>> 40;
        pal[n + i] = (palette[i] >>> 20) & 0xFFFFF;
        pal[2 * n + i] = palette[i] & 0xFFFFF;
      }
    }
  }

  // Builds the smallest codestream for one predictor (5 = clamped gradient,
  // 6 = self-correcting weighted). WP wins on photographic/tonal content,
  // gradient on line art; the encoder tries both and keeps the smaller.
  // Pass A + tree learning for one predictor (5 = clamped gradient, 6 =
  // self-correcting weighted). Split out from the rest so the two predictors'
  // learned trees can be compared (via [ContextTree.trainingBits]) before the
  // expensive Pass B + entropy-coding + assembly runs — see the decision
  // below `prep`/`finish`.
  _Prep prep(bool useWp) {
    final predictor = useWp ? 6 : 5;
    // On the RCT colour path the tree may condition on channel index and on
    // the prior channel (cross-channel context); grayscale/palette can't.
    final List<int> properties = useRct ? (useWp ? rctWpProperties : rctGradProperties) : (useWp ? wpProperties : gradProperties);
    final strideState = [0];
    final trainProps = <int>[];
    final trainTokens = <int>[];

    // Pass A: residuals per group (and the palette meta channel) plus a
    // strided training set for the context tree. For WP, the max-error
    // (property 15) is captured here so Pass B needn't recompute it.
    final metaValues = <int>[];
    final List<int>? metaMaxErr = useWp ? <int>[] : null;
    if (pal != null) {
      _tileResiduals(pal, palette!.length, 0, 0, palette.length, paletteChannels, metaValues, metaMaxErr, trainProps, trainTokens, stride, strideState, useWp, properties);
    }
    final groupValues = List<List<int>>.generate(groupCount, (_) => []);
    final List<List<int>>? groupMaxErr = useWp ? List<List<int>>.generate(groupCount, (_) => []) : null;
    for (var g = 0; g < groupCount; g++) {
      final int ox = (g % groupsX) * groupDimension;
      final int oy = (g ~/ groupsX) * groupDimension;
      final int tw = (width - ox).clamp(0, groupDimension);
      final int th = (height - oy).clamp(0, groupDimension);
      for (var pi = 0; pi < planes.length; pi++) {
        _tileResiduals(
          planes[pi],
          width,
          ox,
          oy,
          tw,
          th,
          groupValues[g],
          groupMaxErr?[g],
          trainProps,
          trainTokens,
          stride,
          strideState,
          useWp,
          properties,
          channelIndex: useRct ? pi : 0,
          priorPlane: useRct && pi > 0 ? planes[pi - 1] : null,
        );
      }
    }

    final ContextTree tree = learnContextTree(Int32List.fromList(trainProps), Int32List.fromList(trainTokens), properties);
    return (predictor: predictor, properties: properties, tree: tree, groupValues: groupValues, groupMaxErr: groupMaxErr, metaValues: metaValues, metaMaxErr: metaMaxErr);
  }

  // Sections: the LowFrequencyGlobal section carries the meta channel (and, for small
  // images, all pixel channels); otherwise one section per group. LZ77 windows
  // are per section. Contexts and values share this layout.
  List<List<int>> mkSections(List<int> meta, List<List<int>> groups) => [
    [
      ...meta,
      if (globalChannels)
        for (var g = 0; g < groupCount; g++) ...groups[g],
    ],
    if (!globalChannels)
      for (var g = 0; g < groupCount; g++) groups[g],
  ];

  // Pass B: assign every pixel a context by walking the learned tree. Contexts
  // are predictor-independent (they depend only on the tree and each pixel's
  // causal neighbourhood), so they are computed once per prep and reused for
  // both the single-predictor baseline and the per-leaf-mixed value stream.
  _PassB passB(_Prep p) {
    final ContextTree tree = p.tree;
    final metaContexts = <int>[];
    if (pal != null) {
      _tileContexts(pal, palette!.length, 0, 0, palette.length, paletteChannels, tree, metaContexts, p.metaMaxErr);
    }
    final groupContexts = List<List<int>>.generate(groupCount, (_) => []);
    for (var g = 0; g < groupCount; g++) {
      final int ox = (g % groupsX) * groupDimension;
      final int oy = (g ~/ groupsX) * groupDimension;
      final int tw = (width - ox).clamp(0, groupDimension);
      final int th = (height - oy).clamp(0, groupDimension);
      for (var pi = 0; pi < planes.length; pi++) {
        _tileContexts(planes[pi], width, ox, oy, tw, th, tree, groupContexts[g], p.groupMaxErr?[g], channelIndex: useRct ? pi : 0, priorPlane: useRct && pi > 0 ? planes[pi - 1] : null);
      }
    }
    return (metaContexts: metaContexts, groupContexts: groupContexts, sectionContexts: mkSections(metaContexts, groupContexts));
  }

  // Entropy-codes and assembles the smallest real codestream for one
  // context/value partition and (optional) per-leaf predictor assignment,
  // serializing [tree] with [predictor] (or [leafPredictors] if given).
  // Returns the bytes, a mode label, and the winning entropy mode selector
  // (config index, LZ77, ANS). With [only] set, it skips the candidate search
  // and assembles exactly that one mode — used to code the mixed stream in the
  // baseline's already-chosen mode (the flips only nudge a few residuals, so
  // re-searching every {config}x{plain,LZ77}x{prefix,ANS} candidate would
  // roughly double assembly time for no measured size gain).
  (Uint8List, String, int, bool, bool, bool) assembleStream(
    ContextTree tree,
    int predictor,
    List<List<int>> sectionContexts,
    List<List<int>> sectionValues,
    List<int>? leafPredictors, {
    (int, bool, bool, bool)? only,
  }) {
    final int contextCount = tree.contexts;
    // LZ77 is an expensive hash-chain pass, so each effort is computed lazily
    // and only when a candidate needs it: the shallow (never-worse baseline)
    // matcher whenever any LZ77 candidate is built, the deep matcher only when
    // LZ77 is already beating the plain code (see the gate below), and neither
    // for a plain-mode `only` assembly.
    late final List<Lz77Operations> sectionOpsShallow = [for (var s = 0; s < sectionValues.length; s++) lz77Compress(sectionContexts[s], sectionValues[s])];
    late final List<Lz77Operations> sectionOpsDeep = [for (var s = 0; s < sectionValues.length; s++) lz77Compress(sectionContexts[s], sectionValues[s], effort: Lz77Effort.deep)];

    Uint8List assemble(EntropyCodes codes, bool ans, bool lz, List<Lz77Operations> ops) {
      void writeSectionPayload(BitWriter w, int s) {
        if (ans && lz) {
          codes.encodeAnsLz77Section(w, ops[s]);
        } else if (ans) {
          codes.encodeAnsSection(w, sectionContexts[s], sectionValues[s]);
        } else if (lz) {
          codes.writeOps(w, ops[s]);
        } else {
          for (var i = 0; i < sectionValues[s].length; i++) {
            codes.writeToken(w, sectionContexts[s][i], sectionValues[s][i]);
          }
        }
      }

      final lowFrequencyGlobal = BitWriter();
      lowFrequencyGlobal.writeBool(true); // default lowFrequencyDequantization
      lowFrequencyGlobal.writeBool(true); // has_global_tree
      serializeContextTree(lowFrequencyGlobal, tree, predictor, leafPredictors);
      if (ans) {
        codes.writeAnsHeader(lowFrequencyGlobal);
      } else {
        codes.writeHeader(lowFrequencyGlobal);
      }
      lowFrequencyGlobal.writeBool(true); // use_global_tree
      lowFrequencyGlobal.writeBool(true); // default wp_params
      if (palette != null) {
        lowFrequencyGlobal.writeU32(1, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 1
        lowFrequencyGlobal.writeBits(1, 2); // transform: palette
        lowFrequencyGlobal.writeU32(0, 0, 3, 8, 6, 72, 10, 1096, 13); // begin_c = 0
        lowFrequencyGlobal.writeU32(paletteChannels, 1, 0, 3, 0, 4, 0, 1, 13); // num_c
        lowFrequencyGlobal.writeU32(palette.length, 0, 8, 256, 10, 1280, 12, 5376, 16); // nb_colors
        lowFrequencyGlobal.writeU32(0, 0, 0, 1, 8, 257, 10, 1281, 16); // nb_deltas = 0
        lowFrequencyGlobal.writeBits(0, 4); // d_pred
      } else if (useRct) {
        lowFrequencyGlobal.writeU32(1, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 1
        lowFrequencyGlobal.writeBits(0, 2); // transform: RCT
        lowFrequencyGlobal.writeU32(0, 0, 3, 8, 6, 72, 10, 1096, 13); // begin_c = 0
        lowFrequencyGlobal.writeU32(6, 6, 0, 0, 2, 2, 4, 10, 6); // rct_type = 6 (YCoCg)
      } else {
        lowFrequencyGlobal.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 0
      }
      writeSectionPayload(lowFrequencyGlobal, 0);

      final out = BitWriter();
      writeImageHeader(out, setup);
      writeFrameHeader(out, setup);
      if (singleSection) {
        final Uint8List body = lowFrequencyGlobal.toBytes();
        writeToc(out, [body.length]);
        out.writeBytes(body);
      } else {
        Uint8List writeGroupSection(int s) {
          final w = BitWriter();
          w.writeBool(true); // use_global_tree
          w.writeBool(true); // default wp_params
          w.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms
          writeSectionPayload(w, s);
          return w.toBytes();
        }

        final sections = <Uint8List>[
          lowFrequencyGlobal.toBytes(),
          for (var i = 0; i < lowFrequencyGroupCount; i++) Uint8List(0),
          Uint8List(0),
          for (var g = 0; g < groupCount; g++) writeGroupSection(1 + g),
        ];
        writeToc(out, [for (final s in sections) s.length]);
        sections.forEach(out.writeBytes);
      }
      return out.toBytes();
    }

    String modeStr(HybridIntegerConfig cfg, bool lz, bool ans, bool deep) =>
        '${lz ? (deep ? "lzd" : "lz") : "plain"}+${ans ? "ans" : "prefix"}'
        '/h${cfg.splitExponent}${cfg.msbInToken}${cfg.lsbInToken}';

    // Flattening allocates a list the size of the whole image, so it is sized
    // up front and computed at most once per assembly instead of once per
    // candidate.
    Int32List flatten(List<List<int>> sections) {
      int length = 0;
      for (final s in sections) {
        length += s.length;
      }
      final flat = Int32List(length);
      int offset = 0;
      for (final s in sections) {
        flat.setRange(offset, offset + s.length, s);
        offset += s.length;
      }
      return flat;
    }

    Int32List? flatContextsCache;
    Int32List? flatValuesCache;
    Int32List flatContexts() => flatContextsCache ??= flatten(sectionContexts);
    Int32List flatValues() => flatValuesCache ??= flatten(sectionValues);

    if (only != null) {
      final (int cfgI, bool lz, bool ans, bool deep) = only;
      final HybridIntegerConfig cfg = _hybridConfigs[cfgI];
      final ops = deep ? sectionOpsDeep : sectionOpsShallow;
      final codes = lz
          ? EntropyCodes.buildLz77(contextCount: contextCount, sections: ops, config: cfg)
          : EntropyCodes.build(contextCount: contextCount, contexts: flatContexts(), values: flatValues(), config: cfg);
      return (assemble(codes, ans, lz, ops), modeStr(cfg, lz, ans, deep), cfgI, lz, ans, deep);
    }

    final Int32List allContexts = flatContexts();
    final Int32List allValues = flatValues();
    // For each candidate hybrid-uint config, build the {plain, LZ77} x
    // {prefix, ANS} entropy codes and their size estimates. ANS spends
    // fractional bits (no 1-bit-per-symbol floor); LZ77 copies repeated runs;
    // the config governs how at/above-split residuals tokenize. The LZ77 here
    // uses the shallow (never-worse baseline) matcher; the deep matcher is added
    // below only when it is worth the search.
    final candidates = <(EntropyCodes, bool, bool, int, bool, double)>[];
    double bestPlain = double.infinity;
    double bestShallowLz = double.infinity;
    for (var ci = 0; ci < _hybridConfigs.length; ci++) {
      final HybridIntegerConfig cfg = _hybridConfigs[ci];
      final lzCodes = EntropyCodes.buildLz77(contextCount: contextCount, sections: sectionOpsShallow, config: cfg);
      final plainCodes = EntropyCodes.build(contextCount: contextCount, contexts: allContexts, values: allValues, config: cfg);
      final double plainEst = plainCodes.estimatedBits();
      final double lzEst = lzCodes.estimatedBits();
      if (plainEst < bestPlain) {
        bestPlain = plainEst;
      }
      if (lzEst < bestShallowLz) {
        bestShallowLz = lzEst;
      }
      candidates.add((plainCodes, false, false, ci, false, plainEst));
      candidates.add((lzCodes, false, true, ci, false, lzEst));
      if (plainCodes.ansViable) {
        final double e = plainCodes.ansEstimatedBits();
        if (e < bestPlain) {
          bestPlain = e;
        }
        candidates.add((plainCodes, true, false, ci, false, e));
      }
      if (lzCodes.ansViable) {
        final double e = lzCodes.ansEstimatedBits();
        if (e < bestShallowLz) {
          bestShallowLz = e;
        }
        candidates.add((lzCodes, true, true, ci, false, e));
      }
    }
    // Deep matcher only when LZ77 is already the mode to beat: a greedy parse's
    // coded size is non-monotonic in matcher effort, so the deep parse can be
    // larger than the shallow one (e.g. on a synthetic gradient's zero runs) —
    // keeping the shallow candidates makes the pair never-worse, and gating on
    // "LZ77 beats plain" spares plainly-coded content (photos) the deep search.
    if (bestShallowLz < bestPlain) {
      for (var ci = 0; ci < _hybridConfigs.length; ci++) {
        final HybridIntegerConfig cfg = _hybridConfigs[ci];
        final lzCodes = EntropyCodes.buildLz77(contextCount: contextCount, sections: sectionOpsDeep, config: cfg);
        candidates.add((lzCodes, false, true, ci, true, lzCodes.estimatedBits()));
        if (lzCodes.ansViable) {
          candidates.add((lzCodes, true, true, ci, true, lzCodes.ansEstimatedBits()));
        }
      }
    }
    final double best = candidates.map((c) => c.$6).reduce((a, b) => a < b ? a : b);

    // Candidates within 3% of the best estimate get assembled for real; the
    // smallest actual output wins. This captures near-tie wins (e.g. unified
    // ANS+LZ77 beating LZ77 by a fraction of a percent) that estimates miss.
    final double threshold = best * 1.03;
    Uint8List? bestBytes;
    var bestMode = '';
    var bestCfg = 0;
    var bestLz = false;
    var bestAns = false;
    var bestDeep = false;
    for (final (codes, ans, lz, ci, deep, est) in candidates) {
      if (est > threshold) {
        continue;
      }
      final Uint8List bytes = assemble(codes, ans, lz, deep ? sectionOpsDeep : sectionOpsShallow);
      if (bestBytes == null || bytes.length < bestBytes.length) {
        bestBytes = bytes;
        bestMode = modeStr(codes.config, lz, ans, deep);
        bestCfg = ci;
        bestLz = lz;
        bestAns = ans;
        bestDeep = deep;
      }
    }
    if (bestBytes == null) {
      final (EntropyCodes codes, bool ans, bool lz, int ci, bool deep, _) = candidates.first;
      bestBytes = assemble(codes, ans, lz, deep ? sectionOpsDeep : sectionOpsShallow);
      bestMode = modeStr(codes.config, lz, ans, deep);
      bestCfg = ci;
      bestLz = lz;
      bestAns = ans;
      bestDeep = deep;
    }
    return (bestBytes, bestMode, bestCfg, bestLz, bestAns, bestDeep);
  }

  // Single-predictor baseline for one prep; also returns its winning entropy
  // mode so per-leaf refinement can re-use it.
  (Uint8List, String, (int, bool, bool, bool)) baselineOf(_Prep p, List<List<int>> sectionContexts) {
    final (Uint8List bytes, String mode, int cfg, bool lz, bool ans, bool deep) = assembleStream(p.tree, p.predictor, sectionContexts, mkSections(p.metaValues, p.groupValues), null);
    return (bytes, '${p.predictor == 6 ? "wp" : "grad"}/$mode', (cfg, lz, ans, deep));
  }

  // Per-leaf predictor selection: refine the chosen tree by letting each leaf
  // switch to the alternate [alt]'s predictor wherever that codes its pixels
  // smaller (the residuals for both predictors were computed in Pass A and are
  // aligned index-for-index). The decoder reads a predictor per leaf and keeps
  // WP state live for every pixel whenever any leaf is WP, so a gradient leaf
  // beside a WP leaf reconstructs bit-exactly. Returns the smaller of the
  // single-predictor baseline and the per-leaf-mixed stream (strictly
  // never-worse).
  (Uint8List, String) refineOf(_Prep p, _Prep alt, _PassB ctx, Uint8List baseBytes, String baseLabel, (int, bool, bool, bool) baseSel) {
    final List<int> leafPred = _selectLeafPredictors(p.tree.contexts, p.predictor, alt.predictor, ctx.metaContexts, ctx.groupContexts, p.metaValues, p.groupValues, alt.metaValues, alt.groupValues);
    var flips = 0;
    for (final lp in leafPred) {
      if (lp != p.predictor) {
        flips++;
      }
    }
    // No leaf switched -> the mixed stream is byte-identical to the baseline.
    if (flips == 0) {
      return (baseBytes, baseLabel);
    }

    final List<int> mixedMeta = _mixValues(ctx.metaContexts, p.metaValues, alt.metaValues, leafPred, p.predictor);
    final List<List<int>> mixedGroups = [for (var g = 0; g < groupCount; g++) _mixValues(ctx.groupContexts[g], p.groupValues[g], alt.groupValues[g], leafPred, p.predictor)];
    final (Uint8List mixBytes, String mixMode, _, _, _, _) = assembleStream(p.tree, p.predictor, ctx.sectionContexts, mkSections(mixedMeta, mixedGroups), leafPred, only: baseSel);
    if (mixBytes.length < baseBytes.length) {
      final int wpLeaves = leafPred.where((x) => x == 6).length;
      return (mixBytes, 'leaf(g${leafPred.length - wpLeaves}/w$wpLeaves)/$mixMode');
    }
    return (baseBytes, baseLabel);
  }

  // Predictor selection. Both predictors' Pass A + tree learning always run
  // (learnTree is the single most expensive phase, and its output — the
  // learned tree's training entropy — is the cheapest reliable signal of
  // which predictor will compress better; a pre-tree residual-entropy proxy
  // was measured to mispredict badly, e.g. picking WP where gradient wins by
  // 11%). When one tree's training entropy is clearly lower, only that
  // predictor's Pass B + entropy coding + assembly runs; near-ties
  // (`_kPredictorMargin`) assemble both baselines and keep the smaller. On top
  // of the chosen predictor, per-leaf selection refines that one tree, letting
  // individual leaves switch to the other predictor where it codes their pixels
  // smaller.
  final _Prep gradPrep = prep(false);
  final _Prep wpPrep = prep(true);
  final double gBits = gradPrep.tree.trainingBits;
  final double wBits = wpPrep.tree.trainingBits;

  final Uint8List chosen;
  final String debug;
  if (gBits * _kPredictorMargin < wBits || wBits * _kPredictorMargin < gBits) {
    final bool useWp = wBits < gBits;
    final win = useWp ? wpPrep : gradPrep;
    final lose = useWp ? gradPrep : wpPrep;
    final _PassB ctx = passB(win);
    final (Uint8List bb, String bl, (int, bool, bool, bool) sel) = baselineOf(win, ctx.sectionContexts);
    final (Uint8List bytes, String mode) = refineOf(win, lose, ctx, bb, bl, sel);
    chosen = bytes;
    debug =
        'chose=$mode (skip loser tree; trainBits '
        'g=${gBits.round()} w=${wBits.round()})';
  } else {
    // Near-tie: per-leaf-refine BOTH trees and keep the smaller. The raw
    // single-predictor baselines don't reliably predict which tree refines
    // smaller (a tree whose raw baseline loses can win after per-leaf mixing —
    // e.g. a manga page where raw WP beats raw gradient but the refined
    // gradient tree beats the refined WP tree), and each refinement's mixed
    // stream is assembled in just its baseline's winning mode, so refining both
    // is cheap.
    final _PassB gctx = passB(gradPrep);
    final (Uint8List gbb, String gbl, (int, bool, bool, bool) gsel) = baselineOf(gradPrep, gctx.sectionContexts);
    final (Uint8List gradBytes, String gradMode) = refineOf(gradPrep, wpPrep, gctx, gbb, gbl, gsel);
    final _PassB wctx = passB(wpPrep);
    final (Uint8List wbb, String wbl, (int, bool, bool, bool) wsel) = baselineOf(wpPrep, wctx.sectionContexts);
    final (Uint8List wpBytes, String wpMode) = refineOf(wpPrep, gradPrep, wctx, wbb, wbl, wsel);
    final bool wpWins = wpBytes.length < gradBytes.length;
    chosen = wpWins ? wpBytes : gradBytes;
    debug =
        'chose=${wpWins ? wpMode : gradMode} (near-tie, refined both; '
        'grad=${gradBytes.length} wp=${wpBytes.length})';
  }
  if (const bool.fromEnvironment('jxl.encdebug')) {
    // ignore: avoid_print
    print('palette=${palette?.length} rct=$useRct $debug');
  }
  return chosen;
}
