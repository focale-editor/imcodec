import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';

/// 1D DCT engine using the JXL scaling convention:
///   IDCT_N(c)[j] = c[0] + sum_{n>=1} c[n] * sqrt(2) * cos(pi*n*(j+0.5)/N)
///   DCT_N(x)[k]  = (alpha(k)/N) * sum_j x[j] * cos(pi*k*(j+0.5)/N)
/// Small sizes (<= 8) use direct transposed-LUT evaluation; larger sizes use
/// Lee's O(N log N) recursion with the sqrt(2) factors folded into the
/// lifting steps, matching the naive evaluation to float precision.

/// Inverse square root of two used by the lifting steps.
const double _inverseSquareRootOfTwo = 0.7071067811865476;

/// First rotation weight for the four-point transform.
const double _dct4Weight0 = 0.76536686473017956;

/// Second rotation weight for the four-point transform.
const double _dct4Weight1 = 1.8477590650225733;

/// First rotation weight for the eight-point transform.
const double _dct8Weight0 = 0.72095982200694797;

/// Second rotation weight for the eight-point transform.
const double _dct8Weight1 = 0.85043009476725651;

/// Third rotation weight for the eight-point transform.
const double _dct8Weight2 = 1.2727585805728339;

/// Fourth rotation weight for the eight-point transform.
const double _dct8Weight3 = 3.6245097854115502;

/// Transposed cosine bases indexed by size, output, and input position.
/// The input-position dimension is sequential. Its first entry is one and is
/// folded into the direct-current term by the caller. Sizes up to eight use
/// this table; larger sizes use the recursive transform.
final List<List<Float32List>> _transposedCosineLookupTables = () {
  final double root2 = math.sqrt(2.0);
  return List.generate(4, (l) {
    final int s = 1 << l;
    return List.generate(s, (k) {
      final lut = Float32List(s);
      lut[0] = 1.0;
      for (var n = 1; n < s; n++) {
        lut[n] = root2 * math.cos(math.pi * n * (k + 0.5) / s);
      }
      return lut;
    });
  });
}();

/// Rotation weights used by each level of the recursive transforms.
final List<Float32List> _rotationWeights = List.generate(9, (l) {
  final int n = 1 << l;
  final int h = n >> 1;
  final t = Float32List(h < 1 ? 1 : h);
  for (var j = 0; j < h; j++) {
    t[j] = math.sqrt2 / (2 * math.cos(math.pi * (j + 0.5) / n));
  }
  return t;
});

/// Per-isolate scratch for the recursions (max size 256 -> 2*256 floats per
/// working set; two independent regions for extraction and copies).
final Float32List _scalarScratch = Float32List(1024);

/// Applies a two-point inverse DCT.
void _inverseDct2(Float32List src, int so, Float32List dest, int dOff) {
  final double a = src[so];
  final double b = src[so + 1];
  dest[dOff] = a + b;
  dest[dOff + 1] = a - b;
}

/// Applies a four-point inverse DCT.
void _inverseDct4(Float32List src, int so, Float32List dest, int dOff) {
  final double c0 = src[so];
  final double c1 = src[so + 1];
  final double c2 = src[so + 2];
  final double c3 = src[so + 3];
  final double e0 = c0 + c2;
  final double e1 = c0 - c2;
  final double d1 = (c1 + c3) * _inverseSquareRootOfTwo;
  final double t0 = (c1 + d1) * _dct4Weight0;
  final double t1 = (c1 - d1) * _dct4Weight1;
  dest[dOff] = e0 + t0;
  dest[dOff + 3] = e0 - t0;
  dest[dOff + 1] = e1 + t1;
  dest[dOff + 2] = e1 - t1;
}

/// Applies an eight-point inverse DCT.
void _inverseDct8(Float32List src, int so, Float32List dest, int dOff) {
  final double c0 = src[so];
  final double c1 = src[so + 1];
  final double c2 = src[so + 2];
  final double c3 = src[so + 3];
  final double c4 = src[so + 4];
  final double c5 = src[so + 5];
  final double c6 = src[so + 6];
  final double c7 = src[so + 7];
  // E = idct4 of even coefficients.
  final double ee0 = c0 + c4;
  final double ee1 = c0 - c4;
  final double ed1 = (c2 + c6) * _inverseSquareRootOfTwo;
  final double et0 = (c2 + ed1) * _dct4Weight0;
  final double et1 = (c2 - ed1) * _dct4Weight1;
  final double e0 = ee0 + et0;
  final double e3 = ee0 - et0;
  final double e1 = ee1 + et1;
  final double e2 = ee1 - et1;
  // T = idct4 of the lifted odd sequence.
  final double f1 = (c1 + c3) * _inverseSquareRootOfTwo;
  final double f2 = (c3 + c5) * _inverseSquareRootOfTwo;
  final double f3 = (c5 + c7) * _inverseSquareRootOfTwo;
  final double g0 = c1 + f2;
  final double g1 = c1 - f2;
  final double h1 = (f1 + f3) * _inverseSquareRootOfTwo;
  final double u0 = (f1 + h1) * _dct4Weight0;
  final double u1 = (f1 - h1) * _dct4Weight1;
  final double t0 = (g0 + u0) * _dct8Weight0;
  final double t3 = (g0 - u0) * _dct8Weight3;
  final double t1 = (g1 + u1) * _dct8Weight1;
  final double t2 = (g1 - u1) * _dct8Weight2;
  dest[dOff] = e0 + t0;
  dest[dOff + 7] = e0 - t0;
  dest[dOff + 1] = e1 + t1;
  dest[dOff + 6] = e1 - t1;
  dest[dOff + 2] = e2 + t2;
  dest[dOff + 5] = e2 - t2;
  dest[dOff + 3] = e3 + t3;
  dest[dOff + 4] = e3 - t3;
}

/// Dispatches an inverse DCT no longer than eight samples.
void _inverseDctSmall(Float32List src, int srcOff, Float32List dest, int destOff, int n) {
  switch (n) {
    case 8:
      _inverseDct8(src, srcOff, dest, destOff);
    case 4:
      _inverseDct4(src, srcOff, dest, destOff);
    case 2:
      _inverseDct2(src, srcOff, dest, destOff);
    default:
      dest[destOff] = src[srcOff];
  }
}

/// Recursive IDCT: input and output must not alias; scratch region
/// [so, so + 2n) is free for use.
void _inverseDct(Float32List src, int srcOff, Float32List dest, int destOff, int n, int logN, int so) {
  if (n <= 8) {
    _inverseDctSmall(src, srcOff, dest, destOff, n);
    return;
  }
  final int h = n >> 1;
  final Float32List s = _scalarScratch;
  // Extract even coefficients and the lifted odd sequence.
  for (var r = 0; r < h; r++) {
    s[so + r] = src[srcOff + 2 * r];
  }
  s[so + h] = src[srcOff + 1];
  for (var r = 1; r < h; r++) {
    s[so + h + r] = (src[srcOff + 2 * r - 1] + src[srcOff + 2 * r + 1]) * _inverseSquareRootOfTwo;
  }
  // Recurse: E into dest lower half, T into dest upper half.
  _inverseDct(s, so, dest, destOff, h, logN - 1, so + n);
  _inverseDct(s, so + h, dest, destOff + h, h, logN - 1, so + n);
  // Save T (the upper half) before the butterfly overwrites it.
  for (var j = 0; j < h; j++) {
    s[so + j] = dest[destOff + h + j];
  }
  final Float32List w = _rotationWeights[logN];
  for (var j = 0; j < h; j++) {
    final double e = dest[destOff + j];
    final double o = w[j] * s[so + j];
    dest[destOff + j] = e + o;
    dest[destOff + n - 1 - j] = e - o;
  }
}

/// Applies a direct forward DCT no longer than eight samples.
void _forwardDctSmall(Float32List src, int srcOff, Float32List dest, int destOff, int logN, int n) {
  // G[k] = sum_j x[j] * alpha(k) * cos(pi*k*(j+0.5)/N); the table entry
  // _transposedCosineLookupTables[logN][j][k] is exactly alpha(k)*cos(pi*k*(j+0.5)/N), so accumulate
  // one source row at a time to keep the inner loop sequential.
  final List<Float32List> lutJ = _transposedCosineLookupTables[logN];
  final double x0 = src[srcOff];
  final Float32List lut0 = lutJ[0];
  for (var k = 0; k < n; k++) {
    dest[destOff + k] = x0 * lut0[k];
  }
  for (var j = 1; j < n; j++) {
    final double xj = src[srcOff + j];
    final Float32List lut = lutJ[j];
    for (var k = 0; k < n; k++) {
      dest[destOff + k] += xj * lut[k];
    }
  }
}

/// Recursive unscaled forward transform G_N (caller divides by N).
void _forwardDct(Float32List src, int srcOff, Float32List dest, int destOff, int n, int logN, int so) {
  if (n <= 8) {
    _forwardDctSmall(src, srcOff, dest, destOff, logN, n);
    return;
  }
  final int h = n >> 1;
  final Float32List s = _scalarScratch;
  final Float32List w = _rotationWeights[logN];
  for (var j = 0; j < h; j++) {
    final double a = src[srcOff + j];
    final double b = src[srcOff + n - 1 - j];
    s[so + j] = a + b;
    s[so + h + j] = w[j] * (a - b);
  }
  _forwardDct(s, so, dest, destOff, h, logN - 1, so + n);
  _forwardDct(s, so + h, dest, destOff + h, h, logN - 1, so + n);
  // Copy Gu | Gv aside, then interleave with the lifting transpose.
  for (var j = 0; j < n; j++) {
    s[so + j] = dest[destOff + j];
  }
  for (var r = 0; r < h; r++) {
    dest[destOff + 2 * r] = s[so + r];
  }
  final int gv = so + h;
  dest[destOff + 1] = s[gv] + (h > 1 ? s[gv + 1] * _inverseSquareRootOfTwo : 0);
  for (var r = 1; r < h; r++) {
    final double next = r + 1 < h ? s[gv + r + 1] : 0.0;
    dest[destOff + 2 * r + 1] = (s[gv + r] + next) * _inverseSquareRootOfTwo;
  }
}

/// One row of inverse DCT (DCT-III with jxl scaling).
void inverseDctHorizontal(Float32List src, Float32List dest, int xStartIn, int xStartOut, int xLogLength, int xLength) {
  _inverseDct(src, xStartIn, dest, xStartOut, xLength, xLogLength, 0);
}

/// One row of forward DCT (DCT-II with jxl scaling).
void forwardDctHorizontal(Float32List src, Float32List dest, int xStartIn, int xStartOut, int xLogLength, int xLength) {
  _forwardDct(src, xStartIn, dest, xStartOut, xLength, xLogLength, 0);
  final double invLength = 1.0 / xLength;
  for (var k = 0; k < xLength; k++) {
    dest[xStartOut + k] *= invLength;
  }
}

/// Transposes matrix into.
void transposeMatrixInto(List<Float32List> src, List<Float32List> dest, int srcStartY, int srcStartX, int destStartY, int destStartX, int srcHeight, int srcWidth) {
  for (var y = 0; y < srcHeight; y++) {
    final Float32List srcy = src[srcStartY + y];
    for (var x = 0; x < srcWidth; x++) {
      dest[destStartY + x][destStartX + y] = srcy[srcStartX + x];
    }
  }
}

/// Fused, transpose-free 8x8 inverse DCT (the dominant block size).
void _inverseDct8x8(List<Float32List> src, List<Float32List> dest, int startInY, int startInX, int startOutY, int startOutX, bool transposed) {
  final Float32List t = _scalarScratch;
  for (var k = 0; k < 8; k++) {
    _inverseDct8(src[startInY + k], startInX, t, k << 3);
  }
  if (transposed) {
    for (var x = 0; x < 8; x++) {
      final double c0 = t[x];
      final double c1 = t[8 + x];
      final double c2 = t[16 + x];
      final double c3 = t[24 + x];
      final double c4 = t[32 + x];
      final double c5 = t[40 + x];
      final double c6 = t[48 + x];
      final double c7 = t[56 + x];
      final double ee0 = c0 + c4;
      final double ee1 = c0 - c4;
      final double ed1 = (c2 + c6) * _inverseSquareRootOfTwo;
      final double et0 = (c2 + ed1) * _dct4Weight0;
      final double et1 = (c2 - ed1) * _dct4Weight1;
      final double e0 = ee0 + et0;
      final double e3 = ee0 - et0;
      final double e1 = ee1 + et1;
      final double e2 = ee1 - et1;
      final double f1 = (c1 + c3) * _inverseSquareRootOfTwo;
      final double f2 = (c3 + c5) * _inverseSquareRootOfTwo;
      final double f3 = (c5 + c7) * _inverseSquareRootOfTwo;
      final double g0 = c1 + f2;
      final double g1 = c1 - f2;
      final double h1 = (f1 + f3) * _inverseSquareRootOfTwo;
      final double u0 = (f1 + h1) * _dct4Weight0;
      final double u1 = (f1 - h1) * _dct4Weight1;
      final double t0 = (g0 + u0) * _dct8Weight0;
      final double t3 = (g0 - u0) * _dct8Weight3;
      final double t1 = (g1 + u1) * _dct8Weight1;
      final double t2 = (g1 - u1) * _dct8Weight2;
      final Float32List dr = dest[startOutY + x];
      dr[startOutX] = e0 + t0;
      dr[startOutX + 7] = e0 - t0;
      dr[startOutX + 1] = e1 + t1;
      dr[startOutX + 6] = e1 - t1;
      dr[startOutX + 2] = e2 + t2;
      dr[startOutX + 5] = e2 - t2;
      dr[startOutX + 3] = e3 + t3;
      dr[startOutX + 4] = e3 - t3;
    }
    return;
  }
  final Float32List r0 = dest[startOutY];
  final Float32List r1 = dest[startOutY + 1];
  final Float32List r2 = dest[startOutY + 2];
  final Float32List r3 = dest[startOutY + 3];
  final Float32List r4 = dest[startOutY + 4];
  final Float32List r5 = dest[startOutY + 5];
  final Float32List r6 = dest[startOutY + 6];
  final Float32List r7 = dest[startOutY + 7];
  for (var x = 0; x < 8; x++) {
    final double c0 = t[x];
    final double c1 = t[8 + x];
    final double c2 = t[16 + x];
    final double c3 = t[24 + x];
    final double c4 = t[32 + x];
    final double c5 = t[40 + x];
    final double c6 = t[48 + x];
    final double c7 = t[56 + x];
    final double ee0 = c0 + c4;
    final double ee1 = c0 - c4;
    final double ed1 = (c2 + c6) * _inverseSquareRootOfTwo;
    final double et0 = (c2 + ed1) * _dct4Weight0;
    final double et1 = (c2 - ed1) * _dct4Weight1;
    final double e0 = ee0 + et0;
    final double e3 = ee0 - et0;
    final double e1 = ee1 + et1;
    final double e2 = ee1 - et1;
    final double f1 = (c1 + c3) * _inverseSquareRootOfTwo;
    final double f2 = (c3 + c5) * _inverseSquareRootOfTwo;
    final double f3 = (c5 + c7) * _inverseSquareRootOfTwo;
    final double g0 = c1 + f2;
    final double g1 = c1 - f2;
    final double h1 = (f1 + f3) * _inverseSquareRootOfTwo;
    final double u0 = (f1 + h1) * _dct4Weight0;
    final double u1 = (f1 - h1) * _dct4Weight1;
    final double t0 = (g0 + u0) * _dct8Weight0;
    final double t3 = (g0 - u0) * _dct8Weight3;
    final double t1 = (g1 + u1) * _dct8Weight1;
    final double t2 = (g1 - u1) * _dct8Weight2;
    final int ox = startOutX + x;
    r0[ox] = e0 + t0;
    r7[ox] = e0 - t0;
    r1[ox] = e1 + t1;
    r6[ox] = e1 - t1;
    r2[ox] = e2 + t2;
    r5[ox] = e2 - t2;
    r3[ox] = e3 + t3;
    r4[ox] = e3 - t3;
  }
}

/// 2D inverse DCT of a (height x width) block from src(startIn) into
/// dest(startOut). Scratch spaces must be at least max(dim) square.
void inverseDct2d(
  List<Float32List> src,
  List<Float32List> dest,
  int startInY,
  int startInX,
  int startOutY,
  int startOutX,
  int height,
  int width,
  List<Float32List> scratch0,
  List<Float32List> scratch1,
  bool transposed,
) {
  if (height == 8 && width == 8) {
    _inverseDct8x8(src, dest, startInY, startInX, startOutY, startOutX, transposed);
    return;
  }
  final int logHeight = ceilLog2(height);
  final int logWidth = ceilLog2(width);
  if (transposed) {
    for (var y = 0; y < height; y++) {
      inverseDctHorizontal(src[startInY + y], scratch1[y], startInX, 0, logWidth, width);
    }
    transposeMatrixInto(scratch1, scratch0, 0, 0, 0, 0, height, width);
    for (var y = 0; y < width; y++) {
      inverseDctHorizontal(scratch0[y], dest[startOutY + y], 0, startOutX, logHeight, height);
    }
  } else {
    transposeMatrixInto(src, scratch0, startInY, startInX, 0, 0, height, width);
    for (var y = 0; y < width; y++) {
      inverseDctHorizontal(scratch0[y], scratch1[y], 0, 0, logHeight, height);
    }
    transposeMatrixInto(scratch1, scratch0, 0, 0, 0, 0, width, height);
    for (var y = 0; y < height; y++) {
      inverseDctHorizontal(scratch0[y], dest[startOutY + y], 0, startOutX, logWidth, width);
    }
  }
}

/// 2D forward DCT (used to produce LLF coefficients from LF values).
void forwardDct2d(
  List<Float32List> src,
  List<Float32List> dest,
  int startInY,
  int startInX,
  int startOutY,
  int startOutX,
  int height,
  int width,
  List<Float32List> scratch0,
  List<Float32List> scratch1,
) {
  final int yLogLength = ceilLog2(height);
  final int xLogLength = ceilLog2(width);
  for (var y = 0; y < height; y++) {
    forwardDctHorizontal(src[y + startInY], scratch0[y], startInX, 0, xLogLength, width);
  }
  transposeMatrixInto(scratch0, scratch1, 0, 0, 0, 0, height, width);
  for (var x = 0; x < width; x++) {
    forwardDctHorizontal(scratch1[x], scratch0[x], 0, 0, yLogLength, height);
  }
  transposeMatrixInto(scratch0, dest, 0, 0, startOutY, startOutX, width, height);
}

/// Fully-SIMD fused 8x8 inverse DCT: rows-in-vector loads, two in-register
/// 8x8 transposes (quadrant shuffleMix), four vector butterfly passes.
/// Offsets are in Float32x4 units; callers guarantee 8-pixel alignment.
void inverseDct8x8Simd(List<Float32x4List> src, List<Float32x4List> dest, int srcY, int srcVX, int destY, int destVX) {
  final vis2 = Float32x4.splat(_inverseSquareRootOfTwo);
  final vw40 = Float32x4.splat(_dct4Weight0);
  final vw41 = Float32x4.splat(_dct4Weight1);
  final vw80 = Float32x4.splat(_dct8Weight0);
  final vw81 = Float32x4.splat(_dct8Weight1);
  final vw82 = Float32x4.splat(_dct8Weight2);
  final vw83 = Float32x4.splat(_dct8Weight3);
  final Float32x4List r0 = src[srcY + 0];
  final Float32x4 l0 = r0[srcVX];
  final Float32x4 h0 = r0[srcVX + 1];
  final Float32x4List r1 = src[srcY + 1];
  final Float32x4 l1 = r1[srcVX];
  final Float32x4 h1 = r1[srcVX + 1];
  final Float32x4List r2 = src[srcY + 2];
  final Float32x4 l2 = r2[srcVX];
  final Float32x4 h2 = r2[srcVX + 1];
  final Float32x4List r3 = src[srcY + 3];
  final Float32x4 l3 = r3[srcVX];
  final Float32x4 h3 = r3[srcVX + 1];
  final Float32x4List r4 = src[srcY + 4];
  final Float32x4 l4 = r4[srcVX];
  final Float32x4 h4 = r4[srcVX + 1];
  final Float32x4List r5 = src[srcY + 5];
  final Float32x4 l5 = r5[srcVX];
  final Float32x4 h5 = r5[srcVX + 1];
  final Float32x4List r6 = src[srcY + 6];
  final Float32x4 l6 = r6[srcVX];
  final Float32x4 h6 = r6[srcVX + 1];
  final Float32x4List r7 = src[srcY + 7];
  final Float32x4 l7 = r7[srcVX];
  final Float32x4 h7 = r7[srcVX + 1];
  {
    final Float32x4 tas0 = l0.shuffleMix(l1, Float32x4.xzxz);
    final Float32x4 tas1 = l0.shuffleMix(l1, Float32x4.ywyw);
    final Float32x4 tas2 = l2.shuffleMix(l3, Float32x4.xzxz);
    final Float32x4 tas3 = l2.shuffleMix(l3, Float32x4.ywyw);
    final Float32x4 a0 = tas0.shuffleMix(tas2, Float32x4.xzxz);
    final Float32x4 a1 = tas1.shuffleMix(tas3, Float32x4.xzxz);
    final Float32x4 a2 = tas0.shuffleMix(tas2, Float32x4.ywyw);
    final Float32x4 a3 = tas1.shuffleMix(tas3, Float32x4.ywyw);
    final Float32x4 tbs0 = h0.shuffleMix(h1, Float32x4.xzxz);
    final Float32x4 tbs1 = h0.shuffleMix(h1, Float32x4.ywyw);
    final Float32x4 tbs2 = h2.shuffleMix(h3, Float32x4.xzxz);
    final Float32x4 tbs3 = h2.shuffleMix(h3, Float32x4.ywyw);
    final Float32x4 a4 = tbs0.shuffleMix(tbs2, Float32x4.xzxz);
    final Float32x4 a5 = tbs1.shuffleMix(tbs3, Float32x4.xzxz);
    final Float32x4 a6 = tbs0.shuffleMix(tbs2, Float32x4.ywyw);
    final Float32x4 a7 = tbs1.shuffleMix(tbs3, Float32x4.ywyw);
    final Float32x4 tcs0 = l4.shuffleMix(l5, Float32x4.xzxz);
    final Float32x4 tcs1 = l4.shuffleMix(l5, Float32x4.ywyw);
    final Float32x4 tcs2 = l6.shuffleMix(l7, Float32x4.xzxz);
    final Float32x4 tcs3 = l6.shuffleMix(l7, Float32x4.ywyw);
    final Float32x4 b0 = tcs0.shuffleMix(tcs2, Float32x4.xzxz);
    final Float32x4 b1 = tcs1.shuffleMix(tcs3, Float32x4.xzxz);
    final Float32x4 b2 = tcs0.shuffleMix(tcs2, Float32x4.ywyw);
    final Float32x4 b3 = tcs1.shuffleMix(tcs3, Float32x4.ywyw);
    final Float32x4 tds0 = h4.shuffleMix(h5, Float32x4.xzxz);
    final Float32x4 tds1 = h4.shuffleMix(h5, Float32x4.ywyw);
    final Float32x4 tds2 = h6.shuffleMix(h7, Float32x4.xzxz);
    final Float32x4 tds3 = h6.shuffleMix(h7, Float32x4.ywyw);
    final Float32x4 b4 = tds0.shuffleMix(tds2, Float32x4.xzxz);
    final Float32x4 b5 = tds1.shuffleMix(tds3, Float32x4.xzxz);
    final Float32x4 b6 = tds0.shuffleMix(tds2, Float32x4.ywyw);
    final Float32x4 b7 = tds1.shuffleMix(tds3, Float32x4.ywyw);
    final Float32x4 paee0 = a0 + a4;
    final Float32x4 paee1 = a0 - a4;
    final Float32x4 paed1 = (a2 + a6) * vis2;
    final Float32x4 paet0 = (a2 + paed1) * vw40;
    final Float32x4 paet1 = (a2 - paed1) * vw41;
    final Float32x4 pae0 = paee0 + paet0;
    final Float32x4 pae3 = paee0 - paet0;
    final Float32x4 pae1 = paee1 + paet1;
    final Float32x4 pae2 = paee1 - paet1;
    final Float32x4 paf1 = (a1 + a3) * vis2;
    final Float32x4 paf2 = (a3 + a5) * vis2;
    final Float32x4 paf3 = (a5 + a7) * vis2;
    final Float32x4 pag0 = a1 + paf2;
    final Float32x4 pag1 = a1 - paf2;
    final Float32x4 pah1 = (paf1 + paf3) * vis2;
    final Float32x4 pau0 = (paf1 + pah1) * vw40;
    final Float32x4 pau1 = (paf1 - pah1) * vw41;
    final Float32x4 pat0 = (pag0 + pau0) * vw80;
    final Float32x4 pat3 = (pag0 - pau0) * vw83;
    final Float32x4 pat1 = (pag1 + pau1) * vw81;
    final Float32x4 pat2 = (pag1 - pau1) * vw82;
    final Float32x4 pa0 = pae0 + pat0;
    final Float32x4 pa7 = pae0 - pat0;
    final Float32x4 pa1 = pae1 + pat1;
    final Float32x4 pa6 = pae1 - pat1;
    final Float32x4 pa2 = pae2 + pat2;
    final Float32x4 pa5 = pae2 - pat2;
    final Float32x4 pa3 = pae3 + pat3;
    final Float32x4 pa4 = pae3 - pat3;
    final Float32x4 pbee0 = b0 + b4;
    final Float32x4 pbee1 = b0 - b4;
    final Float32x4 pbed1 = (b2 + b6) * vis2;
    final Float32x4 pbet0 = (b2 + pbed1) * vw40;
    final Float32x4 pbet1 = (b2 - pbed1) * vw41;
    final Float32x4 pbe0 = pbee0 + pbet0;
    final Float32x4 pbe3 = pbee0 - pbet0;
    final Float32x4 pbe1 = pbee1 + pbet1;
    final Float32x4 pbe2 = pbee1 - pbet1;
    final Float32x4 pbf1 = (b1 + b3) * vis2;
    final Float32x4 pbf2 = (b3 + b5) * vis2;
    final Float32x4 pbf3 = (b5 + b7) * vis2;
    final Float32x4 pbg0 = b1 + pbf2;
    final Float32x4 pbg1 = b1 - pbf2;
    final Float32x4 pbh1 = (pbf1 + pbf3) * vis2;
    final Float32x4 pbu0 = (pbf1 + pbh1) * vw40;
    final Float32x4 pbu1 = (pbf1 - pbh1) * vw41;
    final Float32x4 pbt0 = (pbg0 + pbu0) * vw80;
    final Float32x4 pbt3 = (pbg0 - pbu0) * vw83;
    final Float32x4 pbt1 = (pbg1 + pbu1) * vw81;
    final Float32x4 pbt2 = (pbg1 - pbu1) * vw82;
    final Float32x4 pb0 = pbe0 + pbt0;
    final Float32x4 pb7 = pbe0 - pbt0;
    final Float32x4 pb1 = pbe1 + pbt1;
    final Float32x4 pb6 = pbe1 - pbt1;
    final Float32x4 pb2 = pbe2 + pbt2;
    final Float32x4 pb5 = pbe2 - pbt2;
    final Float32x4 pb3 = pbe3 + pbt3;
    final Float32x4 pb4 = pbe3 - pbt3;
    final Float32x4 uas0 = pa0.shuffleMix(pa1, Float32x4.xzxz);
    final Float32x4 uas1 = pa0.shuffleMix(pa1, Float32x4.ywyw);
    final Float32x4 uas2 = pa2.shuffleMix(pa3, Float32x4.xzxz);
    final Float32x4 uas3 = pa2.shuffleMix(pa3, Float32x4.ywyw);
    final Float32x4 rl0 = uas0.shuffleMix(uas2, Float32x4.xzxz);
    final Float32x4 rl1 = uas1.shuffleMix(uas3, Float32x4.xzxz);
    final Float32x4 rl2 = uas0.shuffleMix(uas2, Float32x4.ywyw);
    final Float32x4 rl3 = uas1.shuffleMix(uas3, Float32x4.ywyw);
    final Float32x4 ubs0 = pa4.shuffleMix(pa5, Float32x4.xzxz);
    final Float32x4 ubs1 = pa4.shuffleMix(pa5, Float32x4.ywyw);
    final Float32x4 ubs2 = pa6.shuffleMix(pa7, Float32x4.xzxz);
    final Float32x4 ubs3 = pa6.shuffleMix(pa7, Float32x4.ywyw);
    final Float32x4 rh0 = ubs0.shuffleMix(ubs2, Float32x4.xzxz);
    final Float32x4 rh1 = ubs1.shuffleMix(ubs3, Float32x4.xzxz);
    final Float32x4 rh2 = ubs0.shuffleMix(ubs2, Float32x4.ywyw);
    final Float32x4 rh3 = ubs1.shuffleMix(ubs3, Float32x4.ywyw);
    final Float32x4 ucs0 = pb0.shuffleMix(pb1, Float32x4.xzxz);
    final Float32x4 ucs1 = pb0.shuffleMix(pb1, Float32x4.ywyw);
    final Float32x4 ucs2 = pb2.shuffleMix(pb3, Float32x4.xzxz);
    final Float32x4 ucs3 = pb2.shuffleMix(pb3, Float32x4.ywyw);
    final Float32x4 rl4 = ucs0.shuffleMix(ucs2, Float32x4.xzxz);
    final Float32x4 rl5 = ucs1.shuffleMix(ucs3, Float32x4.xzxz);
    final Float32x4 rl6 = ucs0.shuffleMix(ucs2, Float32x4.ywyw);
    final Float32x4 rl7 = ucs1.shuffleMix(ucs3, Float32x4.ywyw);
    final Float32x4 uds0 = pb4.shuffleMix(pb5, Float32x4.xzxz);
    final Float32x4 uds1 = pb4.shuffleMix(pb5, Float32x4.ywyw);
    final Float32x4 uds2 = pb6.shuffleMix(pb7, Float32x4.xzxz);
    final Float32x4 uds3 = pb6.shuffleMix(pb7, Float32x4.ywyw);
    final Float32x4 rh4 = uds0.shuffleMix(uds2, Float32x4.xzxz);
    final Float32x4 rh5 = uds1.shuffleMix(uds3, Float32x4.xzxz);
    final Float32x4 rh6 = uds0.shuffleMix(uds2, Float32x4.ywyw);
    final Float32x4 rh7 = uds1.shuffleMix(uds3, Float32x4.ywyw);
    final Float32x4 qaee0 = rl0 + rl4;
    final Float32x4 qaee1 = rl0 - rl4;
    final Float32x4 qaed1 = (rl2 + rl6) * vis2;
    final Float32x4 qaet0 = (rl2 + qaed1) * vw40;
    final Float32x4 qaet1 = (rl2 - qaed1) * vw41;
    final Float32x4 qae0 = qaee0 + qaet0;
    final Float32x4 qae3 = qaee0 - qaet0;
    final Float32x4 qae1 = qaee1 + qaet1;
    final Float32x4 qae2 = qaee1 - qaet1;
    final Float32x4 qaf1 = (rl1 + rl3) * vis2;
    final Float32x4 qaf2 = (rl3 + rl5) * vis2;
    final Float32x4 qaf3 = (rl5 + rl7) * vis2;
    final Float32x4 qag0 = rl1 + qaf2;
    final Float32x4 qag1 = rl1 - qaf2;
    final Float32x4 qah1 = (qaf1 + qaf3) * vis2;
    final Float32x4 qau0 = (qaf1 + qah1) * vw40;
    final Float32x4 qau1 = (qaf1 - qah1) * vw41;
    final Float32x4 qat0 = (qag0 + qau0) * vw80;
    final Float32x4 qat3 = (qag0 - qau0) * vw83;
    final Float32x4 qat1 = (qag1 + qau1) * vw81;
    final Float32x4 qat2 = (qag1 - qau1) * vw82;
    final Float32x4 ol0 = qae0 + qat0;
    final Float32x4 ol7 = qae0 - qat0;
    final Float32x4 ol1 = qae1 + qat1;
    final Float32x4 ol6 = qae1 - qat1;
    final Float32x4 ol2 = qae2 + qat2;
    final Float32x4 ol5 = qae2 - qat2;
    final Float32x4 ol3 = qae3 + qat3;
    final Float32x4 ol4 = qae3 - qat3;
    final Float32x4 qbee0 = rh0 + rh4;
    final Float32x4 qbee1 = rh0 - rh4;
    final Float32x4 qbed1 = (rh2 + rh6) * vis2;
    final Float32x4 qbet0 = (rh2 + qbed1) * vw40;
    final Float32x4 qbet1 = (rh2 - qbed1) * vw41;
    final Float32x4 qbe0 = qbee0 + qbet0;
    final Float32x4 qbe3 = qbee0 - qbet0;
    final Float32x4 qbe1 = qbee1 + qbet1;
    final Float32x4 qbe2 = qbee1 - qbet1;
    final Float32x4 qbf1 = (rh1 + rh3) * vis2;
    final Float32x4 qbf2 = (rh3 + rh5) * vis2;
    final Float32x4 qbf3 = (rh5 + rh7) * vis2;
    final Float32x4 qbg0 = rh1 + qbf2;
    final Float32x4 qbg1 = rh1 - qbf2;
    final Float32x4 qbh1 = (qbf1 + qbf3) * vis2;
    final Float32x4 qbu0 = (qbf1 + qbh1) * vw40;
    final Float32x4 qbu1 = (qbf1 - qbh1) * vw41;
    final Float32x4 qbt0 = (qbg0 + qbu0) * vw80;
    final Float32x4 qbt3 = (qbg0 - qbu0) * vw83;
    final Float32x4 qbt1 = (qbg1 + qbu1) * vw81;
    final Float32x4 qbt2 = (qbg1 - qbu1) * vw82;
    final Float32x4 oh0 = qbe0 + qbt0;
    final Float32x4 oh7 = qbe0 - qbt0;
    final Float32x4 oh1 = qbe1 + qbt1;
    final Float32x4 oh6 = qbe1 - qbt1;
    final Float32x4 oh2 = qbe2 + qbt2;
    final Float32x4 oh5 = qbe2 - qbt2;
    final Float32x4 oh3 = qbe3 + qbt3;
    final Float32x4 oh4 = qbe3 - qbt3;
    final Float32x4List d0 = dest[destY + 0];
    d0[destVX] = ol0;
    d0[destVX + 1] = oh0;
    final Float32x4List d1 = dest[destY + 1];
    d1[destVX] = ol1;
    d1[destVX + 1] = oh1;
    final Float32x4List d2 = dest[destY + 2];
    d2[destVX] = ol2;
    d2[destVX + 1] = oh2;
    final Float32x4List d3 = dest[destY + 3];
    d3[destVX] = ol3;
    d3[destVX + 1] = oh3;
    final Float32x4List d4 = dest[destY + 4];
    d4[destVX] = ol4;
    d4[destVX + 1] = oh4;
    final Float32x4List d5 = dest[destY + 5];
    d5[destVX] = ol5;
    d5[destVX + 1] = oh5;
    final Float32x4List d6 = dest[destY + 6];
    d6[destVX] = ol6;
    d6[destVX + 1] = oh6;
    final Float32x4List d7 = dest[destY + 7];
    d7[destVX] = ol7;
    d7[destVX + 1] = oh7;
  }
}

// ---------------------------------------------------------------------------
// Batched-vector inverse DCT: the 1D recursion applied to Float32x4 elements
// (4 image columns, or 4 rows after an in-register transpose, per lane).

/// Four-lane scratch storage used by recursive inverse transforms.
final Float32x4List _vectorScratch = Float32x4List(1024);

/// First four-lane sequence used by two-dimensional transforms.
final Float32x4List _firstVectorSequence = Float32x4List(256);

/// Second four-lane sequence used by two-dimensional transforms.
final Float32x4List _secondVectorSequence = Float32x4List(256);

/// Intermediate four-lane rows used between transform dimensions.
final List<Float32x4List> _intermediateVectors = List.generate(256, (_) => Float32x4List(64), growable: false);

/// Applies an eight-point inverse DCT to four lanes in parallel.
void _inverseDct8Vector(Float32x4List src, int so, Float32x4List dest, int dOff) {
  final Float32x4 c0 = src[so];
  final Float32x4 c1 = src[so + 1];
  final Float32x4 c2 = src[so + 2];
  final Float32x4 c3 = src[so + 3];
  final Float32x4 c4 = src[so + 4];
  final Float32x4 c5 = src[so + 5];
  final Float32x4 c6 = src[so + 6];
  final Float32x4 c7 = src[so + 7];
  final Float32x4 ee0 = c0 + c4;
  final Float32x4 ee1 = c0 - c4;
  final Float32x4 ed1 = (c2 + c6).scale(_inverseSquareRootOfTwo);
  final Float32x4 et0 = (c2 + ed1).scale(_dct4Weight0);
  final Float32x4 et1 = (c2 - ed1).scale(_dct4Weight1);
  final Float32x4 e0 = ee0 + et0;
  final Float32x4 e3 = ee0 - et0;
  final Float32x4 e1 = ee1 + et1;
  final Float32x4 e2 = ee1 - et1;
  final Float32x4 f1 = (c1 + c3).scale(_inverseSquareRootOfTwo);
  final Float32x4 f2 = (c3 + c5).scale(_inverseSquareRootOfTwo);
  final Float32x4 f3 = (c5 + c7).scale(_inverseSquareRootOfTwo);
  final Float32x4 g0 = c1 + f2;
  final Float32x4 g1 = c1 - f2;
  final Float32x4 h1 = (f1 + f3).scale(_inverseSquareRootOfTwo);
  final Float32x4 u0 = (f1 + h1).scale(_dct4Weight0);
  final Float32x4 u1 = (f1 - h1).scale(_dct4Weight1);
  final Float32x4 t0 = (g0 + u0).scale(_dct8Weight0);
  final Float32x4 t3 = (g0 - u0).scale(_dct8Weight3);
  final Float32x4 t1 = (g1 + u1).scale(_dct8Weight1);
  final Float32x4 t2 = (g1 - u1).scale(_dct8Weight2);
  dest[dOff] = e0 + t0;
  dest[dOff + 7] = e0 - t0;
  dest[dOff + 1] = e1 + t1;
  dest[dOff + 6] = e1 - t1;
  dest[dOff + 2] = e2 + t2;
  dest[dOff + 5] = e2 - t2;
  dest[dOff + 3] = e3 + t3;
  dest[dOff + 4] = e3 - t3;
}

/// Vector analogue of [_inverseDct]; input and output must not alias.
void _inverseDctVector(Float32x4List src, int srcOff, Float32x4List dest, int destOff, int n, int logN, int so) {
  if (n == 8) {
    _inverseDct8Vector(src, srcOff, dest, destOff);
    return;
  }
  final int h = n >> 1;
  final Float32x4List s = _vectorScratch;
  for (var r = 0; r < h; r++) {
    s[so + r] = src[srcOff + 2 * r];
  }
  s[so + h] = src[srcOff + 1];
  for (var r = 1; r < h; r++) {
    s[so + h + r] = (src[srcOff + 2 * r - 1] + src[srcOff + 2 * r + 1]).scale(_inverseSquareRootOfTwo);
  }
  _inverseDctVector(s, so, dest, destOff, h, logN - 1, so + n);
  _inverseDctVector(s, so + h, dest, destOff + h, h, logN - 1, so + n);
  for (var j = 0; j < h; j++) {
    s[so + j] = dest[destOff + h + j];
  }
  final Float32List w = _rotationWeights[logN];
  for (var j = 0; j < h; j++) {
    final Float32x4 e = dest[destOff + j];
    final Float32x4 o = s[so + j].scale(w[j]);
    dest[destOff + j] = e + o;
    dest[destOff + n - 1 - j] = e - o;
  }
}

/// SIMD 2D inverse DCT for non-transposed blocks with height and width
/// both >= 8. Column transforms use 4 adjacent columns per lane directly;
/// row transforms go through in-register 4x4 transposes. Offsets are in
/// Float32x4 units.
void inverseDct2dSimd(List<Float32x4List> src, List<Float32x4List> dest, int srcY, int srcVX, int destY, int destVX, int height, int width) {
  final int logH = ceilLog2(height);
  final int logW = ceilLog2(width);
  final int w4 = width >> 2;
  for (var g = 0; g < w4; g++) {
    for (var k = 0; k < height; k++) {
      _firstVectorSequence[k] = src[srcY + k][srcVX + g];
    }
    _inverseDctVector(_firstVectorSequence, 0, _secondVectorSequence, 0, height, logH, 0);
    for (var k = 0; k < height; k++) {
      _intermediateVectors[k][g] = _secondVectorSequence[k];
    }
  }
  for (var r = 0; r < height; r += 4) {
    final Float32x4List i0 = _intermediateVectors[r];
    final Float32x4List i1 = _intermediateVectors[r + 1];
    final Float32x4List i2 = _intermediateVectors[r + 2];
    final Float32x4List i3 = _intermediateVectors[r + 3];
    for (var vj = 0; vj < w4; vj++) {
      final Float32x4 a = i0[vj];
      final Float32x4 b = i1[vj];
      final Float32x4 cc = i2[vj];
      final Float32x4 d = i3[vj];
      final Float32x4 s0 = a.shuffleMix(b, Float32x4.xzxz);
      final Float32x4 s1 = a.shuffleMix(b, Float32x4.ywyw);
      final Float32x4 s2 = cc.shuffleMix(d, Float32x4.xzxz);
      final Float32x4 s3 = cc.shuffleMix(d, Float32x4.ywyw);
      final int j4 = vj << 2;
      _firstVectorSequence[j4] = s0.shuffleMix(s2, Float32x4.xzxz);
      _firstVectorSequence[j4 + 1] = s1.shuffleMix(s3, Float32x4.xzxz);
      _firstVectorSequence[j4 + 2] = s0.shuffleMix(s2, Float32x4.ywyw);
      _firstVectorSequence[j4 + 3] = s1.shuffleMix(s3, Float32x4.ywyw);
    }
    _inverseDctVector(_firstVectorSequence, 0, _secondVectorSequence, 0, width, logW, 0);
    final Float32x4List d0 = dest[destY + r];
    final Float32x4List d1 = dest[destY + r + 1];
    final Float32x4List d2 = dest[destY + r + 2];
    final Float32x4List d3 = dest[destY + r + 3];
    for (var vj = 0; vj < w4; vj++) {
      final int j4 = vj << 2;
      final Float32x4 a = _secondVectorSequence[j4];
      final Float32x4 b = _secondVectorSequence[j4 + 1];
      final Float32x4 cc = _secondVectorSequence[j4 + 2];
      final Float32x4 d = _secondVectorSequence[j4 + 3];
      final Float32x4 s0 = a.shuffleMix(b, Float32x4.xzxz);
      final Float32x4 s1 = a.shuffleMix(b, Float32x4.ywyw);
      final Float32x4 s2 = cc.shuffleMix(d, Float32x4.xzxz);
      final Float32x4 s3 = cc.shuffleMix(d, Float32x4.ywyw);
      d0[destVX + vj] = s0.shuffleMix(s2, Float32x4.xzxz);
      d1[destVX + vj] = s1.shuffleMix(s3, Float32x4.xzxz);
      d2[destVX + vj] = s0.shuffleMix(s2, Float32x4.ywyw);
      d3[destVX + vj] = s1.shuffleMix(s3, Float32x4.ywyw);
    }
  }
}
