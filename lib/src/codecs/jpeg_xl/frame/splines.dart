import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/limits.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/low_frequency_channel_correlation.dart';

/// The LowFrequencyGlobal splines bundle (control points and 32-coefficient DCTs for
/// the X/Y/B intensities and sigma along each spline).
final class SplinesBundle {
  /// Number of splines.
  late final int splineCount;

  /// Shared dequantization adjustment applied to spline coefficients.
  late final int quantizationAdjustment;

  /// Initial vertical coordinate of each spline.
  late final List<int> splineY;

  /// Initial horizontal coordinate of each spline.
  late final List<int> splineX;

  /// Delta-decoded vertical control points for each spline.
  late final List<List<int>> controlPointsY;

  /// Delta-decoded horizontal control points for each spline.
  late final List<List<int>> controlPointsX;

  /// Horizontal coefficients processed by the splines bundle.
  late final List<List<int>> xCoefficients;

  /// Vertical coefficients processed by the splines bundle.
  late final List<List<int>> yCoefficients;

  /// B coefficients processed by the splines bundle.
  late final List<List<int>> bCoefficients;

  /// Sigma coefficients processed by the splines bundle.
    late final List<List<int>> sigmaCoefficients;

  /// Reads this structure from the bitstream.
    SplinesBundle.read({
    required BitReader reader,
  }) {
    final stream = EntropyStream.read(reader: reader, distributionCount: 6);
    splineCount = 1 + stream.readSymbol(reader, 2);
    if (splineCount > JpegXlLimits.maxFeatureCount) {
      throw const JpegXlInvalidBitstreamException(message: 'too many splines');
    }
    splineY = List.filled(splineCount, 0);
    splineX = List.filled(splineCount, 0);
    for (var i = 0; i < splineCount; i++) {
      int x = stream.readSymbol(reader, 1);
      int y = stream.readSymbol(reader, 1);
      if (i != 0) {
        x = unpackSigned(x) + splineX[i - 1];
        y = unpackSigned(y) + splineY[i - 1];
      }
      splineX[i] = x;
      splineY[i] = y;
    }
    quantizationAdjustment = unpackSigned(stream.readSymbol(reader, 0));
    controlPointsY = List.generate(splineCount, (_) => <int>[]);
    controlPointsX = List.generate(splineCount, (_) => <int>[]);
    xCoefficients = List.generate(splineCount, (_) => List.filled(32, 0));
    yCoefficients = List.generate(splineCount, (_) => List.filled(32, 0));
    bCoefficients = List.generate(splineCount, (_) => List.filled(32, 0));
    sigmaCoefficients = List.generate(splineCount, (_) => List.filled(32, 0));
    for (var i = 0; i < splineCount; i++) {
      final int count = 1 + stream.readSymbol(reader, 3);
      if (count > JpegXlLimits.maxFeatureCount) {
        throw const JpegXlInvalidBitstreamException(message: 'too many control points');
      }
      controlPointsY[i].add(splineY[i]);
      controlPointsX[i].add(splineX[i]);
      final List<int> deltaY = List.filled(count - 1, 0);
      final List<int> deltaX = List.filled(count - 1, 0);
      for (var j = 0; j < count - 1; j++) {
        deltaX[j] = unpackSigned(stream.readSymbol(reader, 4));
        deltaY[j] = unpackSigned(stream.readSymbol(reader, 4));
      }
      int cY = splineY[i];
      int cX = splineX[i];
      var dY = 0;
      var dX = 0;
      for (var j = 1; j < count; j++) {
        dY += deltaY[j - 1];
        dX += deltaX[j - 1];
        cY += dY;
        cX += dX;
        controlPointsY[i].add(cY);
        controlPointsX[i].add(cX);
      }
      for (var j = 0; j < 32; j++) {
        xCoefficients[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        yCoefficients[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        bCoefficients[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        sigmaCoefficients[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
    }
    if (!stream.validateFinalState()) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal final ANS state in splines');
    }
  }
}

/// Inverse square root of two used by the cosine series.
const _inverseSquareRootOfTwo = 0.7071067811865476;

/// Inverse square root of eight used while integrating spline coverage.
const _inverseSquareRootOfEight = 0.3535533905932738;

/// Evaluates the inverse cosine series at [position].
double _evaluateInverseCosineSeries(List<double> coefficients, double position) {
  double total = _inverseSquareRootOfTwo * coefficients[0];
  for (var i = 1; i < 32; i++) {
    total += coefficients[i] * math.cos(i * (math.pi / 32) * (position + 0.5));
  }
  return total;
}

/// Draws all splines of the frame onto its (float, pre-color-transform)
/// color channels.
/// Deviates from jxlatte, which renders every spline with spline 0's
/// coefficients (its Spline constructor never stores the spline index);
/// here each spline uses its own coefficients, matching djxl.
void renderSplines(Frame frame) {
  final SplinesBundle? bundle = frame.lowFrequencyGlobal.splines;
  if (bundle == null) {
    return;
  }
  if (frame.colorChannelCount < 3) {
    throw const JpegXlInvalidBitstreamException(message: 'splines require 3 color channels');
  }
  for (var s = 0; s < bundle.splineCount; s++) {
    _renderSpline(frame, bundle, s);
  }
}

/// Renders spline.
void _renderSpline(Frame frame, SplinesBundle bundle, int splineIndex) {
  // Coefficients, with quant adjustment and LF chroma correlation baked in.
  final LowFrequencyChannelCorrelation lfc = frame.lowFrequencyGlobal.lowFrequencyChannelCorrelation;
  final double quantizationAdjustment = bundle.quantizationAdjustment / 8.0;
  final double invQa = quantizationAdjustment >= 0 ? 1.0 / (1.0 + quantizationAdjustment) : 1.0 - quantizationAdjustment;
  final double yAdjust = 0.106066017 * invQa;
  final double xAdjust = 0.005939697 * invQa;
  final double bAdjust = 0.098994949 * invQa;
  final double sigmaAdjust = 0.47135738 * invQa;
  final xCoefficients = List<double>.filled(32, 0);
  final yCoefficients = List<double>.filled(32, 0);
  final bCoefficients = List<double>.filled(32, 0);
  final sigmaCoefficients = List<double>.filled(32, 0);
  for (var i = 0; i < 32; i++) {
    yCoefficients[i] = bundle.yCoefficients[splineIndex][i] * yAdjust;
    xCoefficients[i] = bundle.xCoefficients[splineIndex][i] * xAdjust + lfc.baseCorrelationX * yCoefficients[i];
    bCoefficients[i] = bundle.bCoefficients[splineIndex][i] * bAdjust + lfc.baseCorrelationB * yCoefficients[i];
    sigmaCoefficients[i] = bundle.sigmaCoefficients[splineIndex][i] * sigmaAdjust;
  }

  // Centripetal Catmull-Rom upsampling of the control points (16 segments
  // per span).
  final List<int> yControlPoints = bundle.controlPointsY[splineIndex];
  final List<int> xControlPoints = bundle.controlPointsX[splineIndex];
  final int n = yControlPoints.length;
  List<double> upY;
  List<double> upX;
  if (n == 1) {
    upY = [yControlPoints[0].toDouble()];
    upX = [xControlPoints[0].toDouble()];
  } else {
    final List<double> extY = [2.0 * yControlPoints[0] - yControlPoints[1], ...yControlPoints.map((v) => v.toDouble()), 2.0 * yControlPoints[n - 1] - yControlPoints[n - 2]];
    final List<double> extX = [2.0 * xControlPoints[0] - xControlPoints[1], ...xControlPoints.map((v) => v.toDouble()), 2.0 * xControlPoints[n - 1] - xControlPoints[n - 2]];
    upY = List.filled(16 * (extY.length - 3) + 1, 0);
    upX = List.filled(upY.length, 0);
    final t = List<double>.filled(4, 0);
    final dY = List<double>.filled(3, 0);
    final dX = List<double>.filled(3, 0);
    final aY = List<double>.filled(3, 0);
    final aX = List<double>.filled(3, 0);
    final bY = List<double>.filled(2, 0);
    final bX = List<double>.filled(2, 0);
    for (var i = 0; i < extY.length - 3; i++) {
      upY[i << 4] = extY[i + 1];
      upX[i << 4] = extX[i + 1];
      t[0] = 0;
      for (var k = 0; k < 3; k++) {
        dY[k] = extY[i + k + 1] - extY[i + k];
        dX[k] = extX[i + k + 1] - extX[i + k];
        t[k + 1] = t[k] + math.pow(dY[k] * dY[k] + dX[k] * dX[k], 0.25).toDouble();
      }
      for (var step = 1; step < 16; step++) {
        final double knot = t[1] + 0.0625 * step * (t[2] - t[1]);
        for (var k = 0; k < 3; k++) {
          final double f = (knot - t[k]) / (t[k + 1] - t[k]);
          aY[k] = dY[k] * f + extY[i + k];
          aX[k] = dX[k] * f + extX[i + k];
        }
        for (var k = 0; k < 2; k++) {
          final double f = (knot - t[k]) / (t[k + 2] - t[k]);
          bY[k] = (aY[k + 1] - aY[k]) * f + aY[k];
          bX[k] = (aX[k + 1] - aX[k]) * f + aX[k];
        }
        final double f = (knot - t[1]) / (t[2] - t[1]);
        upY[i * 16 + step] = (bY[1] - bY[0]) * f + bY[0];
        upX[i * 16 + step] = (bX[1] - bX[0]) * f + bX[0];
      }
    }
    upY[upY.length - 1] = yControlPoints[n - 1].toDouble();
    upX[upX.length - 1] = xControlPoints[n - 1].toDouble();
  }

  // Resample to equal arc-length samples.
  const renderDistance = 1.0;
  final arcY = <double>[];
  final arcX = <double>[];
  final arcLen = <double>[];
  double currentY = upY[0];
  double currentX = upX[0];
  var nextID = 0;
  arcY.add(currentY);
  arcX.add(currentX);
  arcLen.add(renderDistance);
  while (nextID < upY.length) {
    var prevY = currentY;
    var prevX = currentX;
    var fromPrevious = 0.0;
    while (true) {
      if (nextID >= upY.length) {
        arcY.add(prevY);
        arcX.add(prevX);
        arcLen.add(fromPrevious);
        break;
      }
      final double nY = upY[nextID];
      final double nX = upX[nextID];
      final double dY = nY - prevY;
      final double dX = nX - prevX;
      final double toNext = math.sqrt(dY * dY + dX * dX);
      if (fromPrevious + toNext >= renderDistance) {
        final double f = (renderDistance - fromPrevious) / toNext;
        currentY = dY * f + prevY;
        currentX = dX * f + prevX;
        arcY.add(currentY);
        arcX.add(currentX);
        arcLen.add(renderDistance);
        break;
      }
      fromPrevious += toNext;
      prevY = nY;
      prevX = nX;
      nextID++;
    }
  }

  final double totalArc = (arcY.length - 2.0) * renderDistance + arcLen.last;
  if (arcY.length > JpegXlLimits.maxFeatureCount) {
    throw const JpegXlInvalidBitstreamException(message: 'spline arc too long');
  }
  if (totalArc <= 0) {
    return;
  }

  final int width = frame.boundsWidth;
  final int height = frame.boundsHeight;
  final int bits = frame.globalMetadata.bitDepth.bitsPerSample;
  for (var c = 0; c < 3; c++) {
    frame.buffer[c].castToFloat(bits);
  }
  final List<List<Float32List>> rows = [for (var c = 0; c < 3; c++) frame.buffer[c].floatRows];
  final values = List<double>.filled(3, 0);
  for (var i = 0; i < arcY.length; i++) {
    final double progress = math.min(1.0, i * renderDistance / totalArc);
    final double t = 31.0 * progress;
    values[0] = _evaluateInverseCosineSeries(xCoefficients, t) * arcLen[i];
    values[1] = _evaluateInverseCosineSeries(yCoefficients, t) * arcLen[i];
    values[2] = _evaluateInverseCosineSeries(bCoefficients, t) * arcLen[i];
    final double sigma = _evaluateInverseCosineSeries(sigmaCoefficients, t);
    final double inverseSigma = 1.0 / sigma;
    final double maxColor = [0.01, values[0], values[1], values[2]].reduce((a, b) => a > b ? a : b);
    final double maxDist = math.sqrt(-2.0 * sigma * sigma * (math.log(0.1) * 3.0 - maxColor));
    final int xBegin = math.max(0, (arcX[i] - maxDist).round());
    final int xEnd = math.min(width - 1, (arcX[i] + maxDist).round());
    final int yBegin = math.max(0, (arcY[i] - maxDist).round());
    final int yEnd = math.min(height - 1, (arcY[i] + maxDist).round());
    for (var c = 0; c < 3; c++) {
      final List<Float32List> fb = rows[c];
      for (var y = yBegin; y <= yEnd; y++) {
        final Float32List fby = fb[y];
        final double dY = y - arcY[i];
        for (var x = xBegin; x <= xEnd; x++) {
          final double dX = x - arcX[i];
          final double distance = math.sqrt(dY * dY + dX * dX);
          double factor = erf((0.5 * distance + _inverseSquareRootOfEight) * inverseSigma);
          factor -= erf((0.5 * distance - _inverseSquareRootOfEight) * inverseSigma);
          fby[x] += 0.25 * values[c] * sigma * factor * factor;
        }
      }
    }
  }
}
