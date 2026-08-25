import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/color/opsin_inverse.dart';
import 'package:imcodec/src/codecs/jpeg_xl/color/transfer_function.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/lf_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl_image.dart';
import 'package:imcodec/src/codecs/jpeg_xl/render/transpose.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Assembles a VarDCT frame's decoded DC ("LF") coefficients — from
/// [Frame.decodeLfOnly] — into a [JpegXlDecodedImage] at the format's fixed 1:8 scale.
///
/// Shared by [JpegXlStreamingDecoder]'s progressive preview ([isPreview] true,
/// the default) and [JpegXlCodestreamDecoder.decode]'s reduced-resolution fast path
/// ([isPreview] false — the result is the caller's actual requested output,
/// not a placeholder to be replaced later).
JpegXlDecodedImage buildDcImage(Frame frame, ImageHeader header, Uint8List? iccProfile, {bool isPreview = true}) {
  final ({int height, int width}) padded = frame.paddedFrameSize;
  final int lfHeight = padded.height >> 3;
  final int lfWidth = padded.width >> 3;

  // Assemble the per-LF-group dequantized DC into full planes (at each
  // channel's subsampled resolution), then bring chroma up to luma
  // resolution by duplication.
  final planes = <List<Float32List>>[];
  for (var c = 0; c < 3; c++) {
    final int sy = frame.header.jpegUpsamplingY[c];
    final int sx = frame.header.jpegUpsamplingX[c];
    final List<Float32List> rows = floatMatrix(lfHeight >> sy, lfWidth >> sx);
    for (var g = 0; g < frame.numLfGroups; g++) {
      final LfGroup? lfg = frame.lfGroups[g];
      if (lfg == null || lfg.lfCoeff == null) {
        throw const JpegXlInvalidBitstreamException(message: 'incomplete DC sections for preview');
      }
      final List<Float32List> src = lfg.lfCoeff!.dequantLFCoeffAt(c);
      final ({int x, int y}) pos = frame.getLFGroupLocation(g);
      final int oy = (pos.y << 8) >> sy;
      final int ox = (pos.x << 8) >> sx;
      for (var y = 0; y < src.length; y++) {
        rows[oy + y].setRange(ox, ox + src[y].length, src[y]);
      }
    }
    if (sy != 0 || sx != 0) {
      final List<Float32List> full = floatMatrix(lfHeight, lfWidth);
      for (var y = 0; y < lfHeight; y++) {
        final Float32List srcRow = rows[y >> sy];
        final Float32List dst = full[y];
        for (var x = 0; x < lfWidth; x++) {
          dst[x] = srcRow[x >> sx];
        }
      }
      planes.add(full);
    } else {
      planes.add(rows);
    }
  }

  return buildDcImageFromRows(planes, lfHeight, lfWidth, frame.header.doYCbCr, header, iccProfile, isPreview: isPreview);
}

/// As [buildDcImage], but from already-decoded float rows — the progressive
/// level-1 LF-frame case, where the DC data comes from a separate frame
/// rather than this frame's own LF groups.
JpegXlDecodedImage buildDcImageFromRows(List<List<Float32List>> planes, int lfHeight, int lfWidth, bool doYCbCr, ImageHeader header, Uint8List? iccProfile, {bool isPreview = true}) {
  if (header.xybEncoded) {
    final ColorEncodingBundle bundle = header.colorEncoding;
    final OpsinInverseMatrix matrix = header.opsinInverseMatrix.getMatrix(bundle.prim, bundle.white);
    matrix.invertXyb(planes[0], planes[1], planes[2], header.toneMapping.intensityTarget);
  } else if (doYCbCr) {
    for (var y = 0; y < lfHeight; y++) {
      final Float32List cbRow = planes[0][y];
      final Float32List yRow = planes[1][y];
      final Float32List crRow = planes[2][y];
      for (var x = 0; x < lfWidth; x++) {
        final double cb = cbRow[x];
        final double yh = yRow[x] + 0.50196078431372549019;
        final double cr = crRow[x];
        cbRow[x] = yh + 1.402 * cr;
        yRow[x] = yh - 0.34413628620102214650 * cb - 0.71413628620102214650 * cr;
        crRow[x] = yh + 1.772 * cb;
      }
    }
  }
  if (header.xybEncoded) {
    final TransferFunction tf = TransferFunction.forTransfer(header.colorEncoding.tf);
    for (var c = 0; c < 3; c++) {
      for (final Float32List row in planes[c]) {
        for (var i = 0; i < row.length; i++) {
          row[i] = tf.fromLinear(row[i]);
        }
      }
    }
  }

  // Crop to the visible 1:8 size and copy into ImageBuffers.
  final int visHeight = ceilDiv(header.size.height, 8);
  final int visWidth = ceilDiv(header.size.width, 8);
  ImageBuffer cropped(List<Float32List> rows) {
    final buf = ImageBuffer.float32(height: visHeight, width: visWidth);
    final List<Float32List> out = buf.floatRows;
    for (var y = 0; y < visHeight; y++) {
      out[y].setRange(0, visWidth, rows[y]);
    }
    return buf;
  }

  final int colors = header.colorChannelCount;
  final channels = <ImageBuffer>[
    if (colors == 1) cropped(planes[1]) else ...[cropped(planes[0]), cropped(planes[1]), cropped(planes[2])],
  ];
  for (var i = 0; i < header.extraChannels.length; i++) {
    final opaque = ImageBuffer.float32(height: visHeight, width: visWidth);
    for (final Float32List row in opaque.floatRows) {
      row.fillRange(0, visWidth, 1.0);
    }
    channels.add(opaque);
  }

  final List<ImageBuffer> oriented = [for (final plane in channels) transposeBuffer(plane, header.orientation)];
  return isPreview
      ? JpegXlDecodedImage.preview(header: header, channels: oriented, iccProfile: iccProfile, width: oriented[0].width, height: oriented[0].height)
      : JpegXlDecodedImage.scaled(header: header, channels: oriented, iccProfile: iccProfile, width: oriented[0].width, height: oriented[0].height);
}
