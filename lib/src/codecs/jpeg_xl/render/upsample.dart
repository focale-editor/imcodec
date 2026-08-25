import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Processes the upsample plane data used by the JPEG XL codec.
///
ImageBuffer _upsamplePlane(Frame frame, ImageBuffer ib, int c) {
  final int color = frame.colorChannelCount;
  final int k = c < color ? frame.header.upsampling : frame.header.ecUpsampling[c - color];
  if (k == 1) {
    return ib;
  }
  final ImageHeader metadata = frame.globalMetadata;
  final int depth = c < color ? metadata.bitDepth.bitsPerSample : metadata.extraChannels[c - color].bitDepth.bitsPerSample;
  ib.castToFloat(depth);
  final List<Float32List> rows = ib.floatRows;
  final int height = ib.height;
  final int width = ib.width;
  final int l = ceilLog1p(k - 1) - 1;
  final List<List<Float32List>> upWeights = metadata.upWeights[l];
  final out = ImageBuffer.float32(height: height * k, width: width * k);
  final List<Float32List> outRows = out.floatRows;
  for (var y = 0; y < height; y++) {
    for (var ky = 0; ky < k; ky++) {
      final Float32List outRow = outRows[y * k + ky];
      for (var x = 0; x < width; x++) {
        for (var kx = 0; kx < k; kx++) {
          final List<Float32List> weights = upWeights[ky * k + kx];
          var total = 0.0;
          double min = double.maxFinite;
          double max = -double.maxFinite;
          for (var iy = 0; iy < 5; iy++) {
            final int newY = mirrorCoordinate(y + iy - 2, height);
            final Float32List row = rows[newY];
            final Float32List wRow = weights[iy];
            for (var ix = 0; ix < 5; ix++) {
              final int newX = mirrorCoordinate(x + ix - 2, width);
              final double sample = row[newX];
              if (sample < min) {
                min = sample;
              }
              if (sample > max) {
                max = sample;
              }
              total += wRow[ix] * sample;
            }
          }
          outRow[x * k + kx] = total < min
              ? min
              : total > max
              ? max
              : total;
        }
      }
    }
  }
  return out;
}

/// Applies frame upsampling in place: scales all channel planes and the
/// frame bounds, and recomputes group geometry.
void upsampleFrame(Frame frame) {
  for (var c = 0; c < frame.buffer.length; c++) {
    frame.buffer[c] = _upsamplePlane(frame, frame.buffer[c], c);
  }
  final int factor = frame.header.upsampling;
  frame.boundsWidth *= factor;
  frame.boundsHeight *= factor;
  frame.boundsX0 *= factor;
  frame.boundsY0 *= factor;
  frame.groupRowStride = ceilDiv(frame.boundsWidth, frame.header.groupDim);
  frame.lfGroupRowStride = ceilDiv(frame.boundsWidth, frame.header.groupDim << 3);
  frame.numGroups = frame.groupRowStride * ceilDiv(frame.boundsHeight, frame.header.groupDim);
  frame.numLfGroups = frame.lfGroupRowStride * ceilDiv(frame.boundsHeight, frame.header.groupDim << 3);
}
