import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/low_frequency_channel_correlation.dart';

/// xorshift128+ with 8 lanes, matching the JXL noise RNG.
/// Every 64-bit lane is stored as an (hi, lo) pair of 32-bit-unsigned `int`s
/// rather than a single 64-bit value: dart2js's `int` cannot exactly
/// represent values, literals, or intermediate shift/multiply results above
/// 2^53, so a direct port (as this class used to be, backed by [Int64List])
/// fails to even compile for web ("integer literal ... can't be represented
/// exactly in JavaScript") and would be silently wrong at runtime even if it
/// did. Every operation below is deliberately mask-before-shift and
/// add-with-carry so no intermediate value ever exceeds 2^32, which keeps
/// every platform (VM, AOT, dart2js, dart2wasm) bit-identical.
final class Xoroshiro128Plus {
  /// Mask selecting the low 64 bits of a seed calculation.
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

  /// First SplitMix64 scrambling multiplier.
  static final BigInt _mul1 = BigInt.parse('bf58476d1ce4e5b9', radix: 16);

  /// Second SplitMix64 scrambling multiplier.
  static final BigInt _mul2 = BigInt.parse('94d049bb133111eb', radix: 16);

  /// High words of the first generator state across eight lanes.
  final Uint32List _state0Hi = Uint32List(8);

  /// Low words of the first generator state across eight lanes.
  final Uint32List _state0Lo = Uint32List(8);

  /// High words of the second generator state across eight lanes.
  final Uint32List _state1Hi = Uint32List(8);

  /// Low words of the second generator state across eight lanes.
  final Uint32List _state1Lo = Uint32List(8);

  /// Generated 32-bit words waiting to be consumed.
  final Uint32List _batch = Uint32List(16);

  /// Current position within batch.
  int _batchPosition = 16;

  /// Creates eight deterministic generator lanes from two 64-bit seeds.
  Xoroshiro128Plus({
    required int seed0Hi,
    required int seed0Lo,
    required int seed1Hi,
    required int seed1Lo,
  }) {
    var (int h, int l) = _add64(seed0Hi, seed0Lo, 0x9e3779b9, 0x7f4a7c15);
    (h, l) = _splitMix64(h, l);
    _state0Hi[0] = h;
    _state0Lo[0] = l;
    (h, l) = _add64(seed1Hi, seed1Lo, 0x9e3779b9, 0x7f4a7c15);
    (h, l) = _splitMix64(h, l);
    _state1Hi[0] = h;
    _state1Lo[0] = l;
    for (var i = 1; i < 8; i++) {
      (h, l) = _splitMix64(_state0Hi[i - 1], _state0Lo[i - 1]);
      _state0Hi[i] = h;
      _state0Lo[i] = l;
      (h, l) = _splitMix64(_state1Hi[i - 1], _state1Lo[i - 1]);
      _state1Hi[i] = h;
      _state1Lo[i] = l;
    }
  }

  /// The seeding-only mixing step: only ~16 calls per [Xoroshiro128Plus] (one per
  /// image group), so exactness via [BigInt] costs nothing that matters,
  /// and removes the error-prone part (a full 64x64 multiply) from the
  /// hand-rolled 32-bit-limb surface entirely.
  static (int, int) _splitMix64(int hi, int lo) {
    BigInt z = (BigInt.from(hi) << 32) | BigInt.from(lo);
    z = ((z ^ (z >> 30)) * _mul1) & _mask64;
    z = ((z ^ (z >> 27)) * _mul2) & _mask64;
    z ^= z >> 31;
    return ((z >> 32).toInt(), (z & BigInt.from(0xFFFFFFFF)).toInt());
  }

  /// 64-bit add mod 2^64 on (hi, lo) uint32 pairs.
  static (int, int) _add64(int aHi, int aLo, int bHi, int bLo) {
    final int loSum = aLo + bLo;
    return ((aHi + bHi + (loSum >> 32)) & 0xFFFFFFFF, loSum & 0xFFFFFFFF);
  }

  /// Fills the destination with the supplied value.
  void fill(Uint32List bits) {
    for (var i = 0; i < bits.length; i++) {
      if (_batchPosition >= 16) {
        _fillBatch();
      }
      bits[i] = _batch[_batchPosition++];
    }
  }

  /// Fills batch.
  void _fillBatch() {
    for (var i = 0; i < 8; i++) {
      final int aHi = _state1Hi[i];
      final int aLo = _state1Lo[i];
      final int bHi = _state0Hi[i];
      final int bLo = _state0Lo[i];
      // c = a + b (64-bit, mod 2^64).
      final int cLoSum = aLo + bLo;
      final int cLo = cLoSum & 0xFFFFFFFF;
      final int cHi = (aHi + bHi + (cLoSum >> 32)) & 0xFFFFFFFF;
      _state0Hi[i] = aHi;
      _state0Lo[i] = aLo;
      // b ^= b << 23 (64-bit shift). Every intermediate below is masked
      // BEFORE shifting (not after) so it never exceeds 2^32 - shifting
      // first and masking after would transiently need up to 2^55, which
      // dart2js's double-backed `int` can't represent exactly.
      final int nbHi = bHi ^ (((bHi & 0x1FF) << 23) | (bLo >>> 9));
      final int nbLo = bLo ^ ((bLo & 0x1FF) << 23);
      // state1 = b ^ a ^ (b >>> 18) ^ (a >>> 5), same 64-bit-shift rule.
      _state1Hi[i] = nbHi ^ aHi ^ (nbHi >>> 18) ^ (aHi >>> 5);
      _state1Lo[i] = nbLo ^ aLo ^ (((nbHi & 0x3FFFF) << 14) | (nbLo >>> 18)) ^ (((aHi & 0x1F) << 27) | (aLo >>> 5));
      _batch[2 * i] = cLo;
      _batch[2 * i + 1] = cHi;
    }
    _batchPosition = 0;
  }
}

/// Specification constant used for laplacian.
const _laplacian = [
  [0.16, 0.16, 0.16, 0.16, 0.16],
  [0.16, 0.16, 0.16, 0.16, 0.16],
  [0.16, 0.16, -3.84, 0.16, 0.16],
  [0.16, 0.16, 0.16, 0.16, 0.16],
  [0.16, 0.16, 0.16, 0.16, 0.16],
];

/// Generates the per-group noise field (uniform [1,2) floats convolved with
/// a Laplacian kernel). Must run after upsampling, before synthesis.
/// [seed0Hi]/[seed0Lo] are the high/low 32 bits of the frame-wide 64-bit
/// seed (kept as a pair rather than one packed 64-bit int for the same
/// web-safety reason as [Xoroshiro128Plus]).
List<List<Float32List>>? initializeNoise(Frame frame, int seed0Hi, int seed0Lo) {
  if (frame.lowFrequencyGlobal.noiseParameters == null) {
    return null;
  }
  final int colors = frame.colorChannelCount;
  final int height = frame.boundsHeight;
  final int width = frame.boundsWidth;
  final List<List<Float32List>> localNoise = [for (var c = 0; c < colors; c++) floatMatrix(height, width)];
  final bitsView = Uint32List(16);
  final floatView = Float32List.view(bitsView.buffer);
  for (var group = 0; group < frame.groupCount; group++) {
    final ({int x, int y}) loc = frame.getGroupLocation(group);
    final int y0 = loc.y << frame.header.logGroupDimension;
    final int x0 = loc.x << frame.header.logGroupDimension;
    final int ySize = frame.header.groupDimension < height - y0 ? frame.header.groupDimension : height - y0;
    final int xSize = frame.header.groupDimension < width - x0 ? frame.header.groupDimension : width - x0;
    final rng = Xoroshiro128Plus(seed0Hi: seed0Hi, seed0Lo: seed0Lo, seed1Hi: x0 & 0xFFFFFFFF, seed1Lo: y0 & 0xFFFFFFFF);
    for (var c = 0; c < colors; c++) {
      for (var y = 0; y < ySize; y++) {
        for (var x = 0; x < xSize; x += 16) {
          rng.fill(bitsView);
          for (var i = 0; i < 16 && x + i < xSize; i++) {
            bitsView[i] = (bitsView[i] >> 9) | 0x3f800000;
            localNoise[c][y0 + y][x0 + x + i] = floatView[i];
          }
        }
      }
    }
  }
  final List<List<Float32List>> noiseBuffer = [for (var c = 0; c < colors; c++) floatMatrix(height, width)];
  for (var c = 0; c < colors; c++) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var total = 0.0;
        for (var iy = 0; iy < 5; iy++) {
          final int cy = mirrorCoordinate(y + iy - 2, height);
          for (var ix = 0; ix < 5; ix++) {
            final int cx = mirrorCoordinate(x + ix - 2, width);
            total += localNoise[c][cy][cx] * _laplacian[iy][ix];
          }
        }
        noiseBuffer[c][y][x] = total;
      }
    }
  }
  return noiseBuffer;
}

/// Adds synthesized noise to the (XYB-space) color channels.
void synthesizeNoise(Frame frame, List<List<Float32List>>? noiseBuffer) {
  final List<double>? lut = frame.lowFrequencyGlobal.noiseParameters;
  if (lut == null || noiseBuffer == null) {
    return;
  }
  final List<List<Float32List>> buffers = [for (var c = 0; c < 3; c++) frame.buffer[c].floatRows];
  final LowFrequencyChannelCorrelation lfc = frame.lowFrequencyGlobal.lowFrequencyChannelCorrelation;
  for (var y = 0; y < frame.boundsHeight; y++) {
    for (var x = 0; x < frame.boundsWidth; x++) {
      double inScaledR = buffers[1][y][x] + buffers[0][y][x];
      inScaledR = inScaledR < 0 ? 0 : 3 * inScaledR;
      double inScaledG = buffers[1][y][x] - buffers[0][y][x];
      inScaledG = inScaledG < 0 ? 0 : 3 * inScaledG;
      int intInR;
      double fracInR;
      if (inScaledR >= 7.0) {
        intInR = 6;
        fracInR = 1.0;
      } else {
        intInR = inScaledR.truncate();
        fracInR = inScaledR - intInR;
      }
      int intInG;
      double fracInG;
      if (inScaledG >= 7.0) {
        intInG = 6;
        fracInG = 1.0;
      } else {
        intInG = inScaledG.truncate();
        fracInG = inScaledG - intInG;
      }
      double sr = (lut[intInR + 1] - lut[intInR]) * fracInR + lut[intInR];
      double sg = (lut[intInG + 1] - lut[intInG]) * fracInG + lut[intInG];
      sr = sr < 0
          ? 0
          : sr > 1
          ? 1
          : sr;
      sg = sg < 0
          ? 0
          : sg > 1
          ? 1
          : sg;
      final double nr = sr * (0.00171875 * noiseBuffer[0][y][x] + 0.21828125 * noiseBuffer[2][y][x]);
      final double ng = sg * (0.00171875 * noiseBuffer[1][y][x] + 0.21828125 * noiseBuffer[2][y][x]);
      final double nrg = nr + ng;
      buffers[1][y][x] += nrg;
      buffers[0][y][x] += lfc.baseCorrelationX * nrg + nr - ng;
      buffers[2][y][x] += lfc.baseCorrelationB * nrg;
    }
  }
}
