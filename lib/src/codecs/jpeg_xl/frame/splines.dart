import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl_limits.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/lf_channel_correlation.dart';

/// The LfGlobal splines bundle (control points and 32-coefficient DCTs for
/// the X/Y/B intensities and sigma along each spline).
final class SplinesBundle {
  /// Stores the num splines value used while processing JPEG XL data.
  ///
  late final int numSplines;

  /// Stores the quant adjust value used while processing JPEG XL data.
  ///
  late final int quantAdjust;

  /// Stores the spline y value used while processing JPEG XL data.
  ///
  late final List<int> splineY;

  /// Stores the spline x value used while processing JPEG XL data.
  ///
  late final List<int> splineX;

  /// Stores the control points y value used while processing JPEG XL data.
  ///
  late final List<List<int>> controlPointsY;

  /// Stores the control points x value used while processing JPEG XL data.
  ///
  late final List<List<int>> controlPointsX;

  /// Stores the coeff x value used while processing JPEG XL data.
  ///
  late final List<List<int>> coeffX;

  /// Stores the coeff y value used while processing JPEG XL data.
  ///
  late final List<List<int>> coeffY;

  /// Stores the coeff b value used while processing JPEG XL data.
  ///
  late final List<List<int>> coeffB;

  /// Stores the coeff sigma value used while processing JPEG XL data.
  ///
  late final List<List<int>> coeffSigma;

  /// Processes read information in a JPEG XL codestream.
  ///
  SplinesBundle.read({
    required BitReader reader,
  }) {
    final stream = EntropyStream.read(reader: reader, numDists: 6);
    numSplines = 1 + stream.readSymbol(reader, 2);
    if (numSplines > JpegXlLimits.maxFeatureCount) {
      throw const JpegXlInvalidBitstreamException(message: 'too many splines');
    }
    splineY = List.filled(numSplines, 0);
    splineX = List.filled(numSplines, 0);
    for (var i = 0; i < numSplines; i++) {
      int x = stream.readSymbol(reader, 1);
      int y = stream.readSymbol(reader, 1);
      if (i != 0) {
        x = unpackSigned(x) + splineX[i - 1];
        y = unpackSigned(y) + splineY[i - 1];
      }
      splineX[i] = x;
      splineY[i] = y;
    }
    quantAdjust = unpackSigned(stream.readSymbol(reader, 0));
    controlPointsY = List.generate(numSplines, (_) => <int>[]);
    controlPointsX = List.generate(numSplines, (_) => <int>[]);
    coeffX = List.generate(numSplines, (_) => List.filled(32, 0));
    coeffY = List.generate(numSplines, (_) => List.filled(32, 0));
    coeffB = List.generate(numSplines, (_) => List.filled(32, 0));
    coeffSigma = List.generate(numSplines, (_) => List.filled(32, 0));
    for (var i = 0; i < numSplines; i++) {
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
        coeffX[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        coeffY[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        coeffB[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        coeffSigma[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
    }
    if (!stream.validateFinalState()) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal final ANS state in splines');
    }
  }
}

/// Processes the sqrt h data used by the JPEG XL codec.
///
const _sqrtH = 0.7071067811865476; // sqrt(0.5)
/// Processes the sqrt f data used by the JPEG XL codec.
///
const _sqrtF = 0.3535533905932738; // sqrt(0.125)

/// Processes the fourier ict data used by the JPEG XL codec.
///
double _fourierICT(List<double> coeffs, double t) {
  double total = _sqrtH * coeffs[0];
  for (var i = 1; i < 32; i++) {
    total += coeffs[i] * math.cos(i * (math.pi / 32) * (t + 0.5));
  }
  return total;
}

/// Draws all splines of the frame onto its (float, pre-color-transform)
/// color channels.
///
/// Deviates from jxlatte, which renders every spline with spline 0's
/// coefficients (its Spline constructor never stores the spline index);
/// here each spline uses its own coefficients, matching djxl.
void renderSplines(Frame frame) {
  final SplinesBundle? bundle = frame.lfGlobal.splines;
  if (bundle == null) {
    return;
  }
  if (frame.colorChannelCount < 3) {
    throw const JpegXlInvalidBitstreamException(message: 'splines require 3 color channels');
  }
  for (var s = 0; s < bundle.numSplines; s++) {
    _renderSpline(frame, bundle, s);
  }
}

/// Renders spline.
///
void _renderSpline(Frame frame, SplinesBundle bundle, int splineID) {
  // Coefficients, with quant adjustment and LF chroma correlation baked in.
  final LfChannelCorrelation lfc = frame.lfGlobal.lfChanCorr;
  final double quantAdjust = bundle.quantAdjust / 8.0;
  final double invQa = quantAdjust >= 0 ? 1.0 / (1.0 + quantAdjust) : 1.0 - quantAdjust;
  final double yAdjust = 0.106066017 * invQa;
  final double xAdjust = 0.005939697 * invQa;
  final double bAdjust = 0.098994949 * invQa;
  final double sigmaAdjust = 0.47135738 * invQa;
  final coeffX = List<double>.filled(32, 0);
  final coeffY = List<double>.filled(32, 0);
  final coeffB = List<double>.filled(32, 0);
  final coeffSigma = List<double>.filled(32, 0);
  for (var i = 0; i < 32; i++) {
    coeffY[i] = bundle.coeffY[splineID][i] * yAdjust;
    coeffX[i] = bundle.coeffX[splineID][i] * xAdjust + lfc.baseCorrelationX * coeffY[i];
    coeffB[i] = bundle.coeffB[splineID][i] * bAdjust + lfc.baseCorrelationB * coeffY[i];
    coeffSigma[i] = bundle.coeffSigma[splineID][i] * sigmaAdjust;
  }

  // Centripetal Catmull-Rom upsampling of the control points (16 segments
  // per span).
  final List<int> cpY = bundle.controlPointsY[splineID];
  final List<int> cpX = bundle.controlPointsX[splineID];
  final int n = cpY.length;
  List<double> upY;
  List<double> upX;
  if (n == 1) {
    upY = [cpY[0].toDouble()];
    upX = [cpX[0].toDouble()];
  } else {
    final List<double> extY = [2.0 * cpY[0] - cpY[1], ...cpY.map((v) => v.toDouble()), 2.0 * cpY[n - 1] - cpY[n - 2]];
    final List<double> extX = [2.0 * cpX[0] - cpX[1], ...cpX.map((v) => v.toDouble()), 2.0 * cpX[n - 1] - cpX[n - 2]];
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
    upY[upY.length - 1] = cpY[n - 1].toDouble();
    upX[upX.length - 1] = cpX[n - 1].toDouble();
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
    values[0] = _fourierICT(coeffX, t) * arcLen[i];
    values[1] = _fourierICT(coeffY, t) * arcLen[i];
    values[2] = _fourierICT(coeffB, t) * arcLen[i];
    final double sigma = _fourierICT(coeffSigma, t);
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
          double factor = erf((0.5 * distance + _sqrtF) * inverseSigma);
          factor -= erf((0.5 * distance - _sqrtF) * inverseSigma);
          fby[x] += 0.25 * values[c] * sigma * factor * factor;
        }
      }
    }
  }
}
