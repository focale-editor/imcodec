import 'dart:convert';

import 'package:imcodec/src/codecs/jpeg_xl/frame/blending_info.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/passes_info.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/restoration_filter.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/extensions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// The frame header bundle, including the resolved frame bounds.
final class FrameHeader {
  /// Stores the group dim value used while processing JPEG XL data.
  ///
  int groupDim = 256;

  /// Processes extensions information in a JPEG XL codestream.
  ///
  Extensions extensions = const Extensions();

  /// Stores the type value used while processing JPEG XL data.
  ///
  int type = FrameFlags.regularFrame;

  /// Stores the encoding value used while processing JPEG XL data.
  ///
  int encoding = FrameFlags.vardct;

  /// Stores the flags value used while processing JPEG XL data.
  ///
  int flags = 0;

  /// Stores the do yCb cr value used while processing JPEG XL data.
  ///
  bool doYCbCr = false;

  /// Stores the jpeg upsampling y value used while processing JPEG XL data.
  ///
  final List<int> jpegUpsamplingY = [0, 0, 0];

  /// Stores the jpeg upsampling x value used while processing JPEG XL data.
  ///
  final List<int> jpegUpsamplingX = [0, 0, 0];

  /// Stores the upsampling value used while processing JPEG XL data.
  ///
  int upsampling = 1;

  /// Stores the ec upsampling value used while processing JPEG XL data.
  ///
  List<int> ecUpsampling = const [];

  /// Stores the group size shift value used while processing JPEG XL data.
  ///
  int groupSizeShift = 1;

  /// Processes restoration filter information in a JPEG XL codestream.
  ///
  RestorationFilter restorationFilter = RestorationFilter.defaults();

  /// Stores the lf group dim value used while processing JPEG XL data.
  ///
  int lfGroupDim = 2048;

  /// Stores the log group dim value used while processing JPEG XL data.
  ///
  int logGroupDim = 8;

  /// Stores the log lf group dim value used while processing JPEG XL data.
  ///
  int logLfGroupDim = 11;

  /// Stores the xqm scale value used while processing JPEG XL data.
  ///
  int xqmScale = 2;

  /// Stores the bqm scale value used while processing JPEG XL data.
  ///
  int bqmScale = 2;

  /// Processes passes information in a JPEG XL codestream.
  ///
  PassesInfo passes = PassesInfo.defaults();

  /// Stores the lf level value used while processing JPEG XL data.
  ///
  int lfLevel = 0;

  /// Stores the have crop value used while processing JPEG XL data.
  ///
  bool haveCrop = false;

  /// Frame bounds: origin can be negative; width/height are the decoded
  /// frame size (after the upsampling/lfLevel adjustments).
  int x0 = 0;

  /// Stores the y0 value used while processing JPEG XL data.
  ///
  int y0 = 0;

  /// Stores the width value used while processing JPEG XL data.
  ///
  int width = 0;

  /// Stores the is subsampled value used while processing JPEG XL data.
  ///
  bool isSubsampled = false;

  /// Stores the full frame value used while processing JPEG XL data.
  ///
  bool fullFrame = true;

  /// Processes blending info information in a JPEG XL codestream.
  ///
  BlendingInfo blendingInfo = const BlendingInfo.defaults();

  /// Stores the ec blending info value used while processing JPEG XL data.
  ///
  List<BlendingInfo> ecBlendingInfo = const [];

  /// Stores the duration value used while processing JPEG XL data.
  ///
  int duration = 0;

  /// Stores the timecode value used while processing JPEG XL data.
  ///
  int timecode = 0;

  /// Stores the is last value used while processing JPEG XL data.
  ///
  bool isLast = true;

  /// Stores the save as reference value used while processing JPEG XL data.
  ///
  int saveAsReference = 0;

  /// Stores the save before cT value used while processing JPEG XL data.
  ///
  bool saveBeforeCT = false;

  /// Stores the name value used while processing JPEG XL data.
  ///
  String name = '';

  /// Stores the height value used while processing JPEG XL data.
  ///
  int height = 0;

  /// Creates Frame header state for JPEG XL processing.
  ///
  FrameHeader._();

  /// Processes read information in a JPEG XL codestream.
  ///
  factory FrameHeader.read({
    required BitReader reader,
    required ImageHeader parent,
  }) {
    final h = FrameHeader._();
    final bool allDefault = reader.readBool();
    h.type = allDefault ? FrameFlags.regularFrame : reader.readBits(2);
    h.encoding = allDefault ? FrameFlags.vardct : reader.readBits(1);
    h.flags = allDefault ? 0 : reader.readU64();
    h.doYCbCr = !allDefault && !parent.xybEncoded && reader.readBool();
    if (h.doYCbCr && h.flags & FrameFlags.useLfFrame == 0) {
      for (var i = 0; i < 3; i++) {
        final int mode = reader.readBits(2);
        switch (mode) {
          case 1:
            h.jpegUpsamplingY[i] = 1;
            h.jpegUpsamplingX[i] = 1;
          case 2:
            h.jpegUpsamplingY[i] = 0;
            h.jpegUpsamplingX[i] = 1;
          case 3:
            h.jpegUpsamplingY[i] = 1;
            h.jpegUpsamplingX[i] = 0;
        }
      }
    }
    h.ecUpsampling = List<int>.filled(parent.extraChannels.length, 1);
    if (!allDefault && h.flags & FrameFlags.useLfFrame == 0) {
      h.upsampling = 1 << reader.readBits(2);
      for (var i = 0; i < h.ecUpsampling.length; i++) {
        h.ecUpsampling[i] = 1 << reader.readBits(2);
      }
    } else {
      h.upsampling = 1;
    }
    h.groupSizeShift = h.encoding == FrameFlags.modular ? reader.readBits(2) : 1;
    h.groupDim = 128 << h.groupSizeShift;
    h.lfGroupDim = h.groupDim << 3;
    h.logGroupDim = ceilLog2(h.groupDim);
    h.logLfGroupDim = ceilLog2(h.lfGroupDim);
    if (parent.xybEncoded && h.encoding == FrameFlags.vardct) {
      h.xqmScale = allDefault ? 3 : reader.readBits(3);
      h.bqmScale = allDefault ? 2 : reader.readBits(3);
    } else {
      h.xqmScale = 2;
      h.bqmScale = 2;
    }
    h.passes = !allDefault && h.type != FrameFlags.referenceOnly ? PassesInfo.read(reader: reader) : PassesInfo.defaults();
    h.lfLevel = h.type == FrameFlags.lfFrame ? 1 + reader.readBits(2) : 0;
    h.haveCrop = !allDefault && h.type != FrameFlags.lfFrame && reader.readBool();
    final int imageWidth = parent.size.width;
    final int imageHeight = parent.size.height;
    if (h.haveCrop && h.type != FrameFlags.referenceOnly) {
      final int x0 = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      final int y0 = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      h.x0 = unpackSigned(x0);
      h.y0 = unpackSigned(y0);
    }
    if (h.haveCrop) {
      h.width = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      h.height = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
    } else {
      h.width = imageWidth;
      h.height = imageHeight;
    }
    final bool normalFrame = !allDefault && (h.type == FrameFlags.regularFrame || h.type == FrameFlags.skipProgressive);
    // Computed before the upsampling/lfLevel divisions, intentionally.
    final bool fullFrame = h.y0 <= 0 && h.x0 <= 0 && h.height + h.y0 >= imageHeight && h.width + h.x0 >= imageWidth;
    h.fullFrame = fullFrame;
    h.height = ceilDiv(h.height, h.upsampling);
    h.width = ceilDiv(h.width, h.upsampling);
    h.height = ceilDiv(h.height, 1 << (3 * h.lfLevel));
    h.width = ceilDiv(h.width, 1 << (3 * h.lfLevel));
    h.ecBlendingInfo = List<BlendingInfo>.filled(parent.extraChannels.length, const BlendingInfo.defaults());
    if (normalFrame) {
      h.blendingInfo = BlendingInfo.read(reader: reader, extra: h.ecBlendingInfo.isNotEmpty, fullFrame: fullFrame);
      for (var i = 0; i < h.ecBlendingInfo.length; i++) {
        h.ecBlendingInfo[i] = BlendingInfo.read(reader: reader, extra: true, fullFrame: fullFrame);
      }
    } else {
      h.blendingInfo = const BlendingInfo.defaults();
    }
    final animated = parent.animation != null;
    h.duration = normalFrame && animated ? reader.readU32(0, 0, 1, 0, 0, 8, 0, 32) : 0;
    h.timecode = normalFrame && animated && parent.animation!.haveTimecodes ? reader.readBits(32) : 0;
    h.isLast = normalFrame ? reader.readBool() : h.type == FrameFlags.regularFrame;
    h.saveAsReference = !allDefault && h.type != FrameFlags.lfFrame && !h.isLast ? reader.readBits(2) : 0;
    h.saveBeforeCT =
        !allDefault &&
        (h.type == FrameFlags.referenceOnly ||
            fullFrame &&
                (h.type == FrameFlags.regularFrame || h.type == FrameFlags.skipProgressive) &&
                (h.duration == 0 || h.saveAsReference != 0) &&
                !h.isLast &&
                h.blendingInfo.mode == FrameFlags.blendReplace) &&
        reader.readBool();
    if (allDefault) {
      h.name = '';
    } else {
      final int nameLen = reader.readU32(0, 0, 0, 4, 16, 5, 48, 10);
      final buffer = List<int>.generate(nameLen, (_) => reader.readBits(8));
      h.name = utf8.decode(buffer, allowMalformed: true);
    }
    h.restorationFilter = allDefault ? RestorationFilter.defaults() : RestorationFilter.read(reader: reader, encoding: h.encoding);
    h.extensions = allDefault ? const Extensions() : Extensions.read(reader: reader);
    var maxJPY = 0;
    var maxJPX = 0;
    for (var i = 0; i < 3; i++) {
      if (h.jpegUpsamplingY[i] > maxJPY) {
        maxJPY = h.jpegUpsamplingY[i];
      }
      if (h.jpegUpsamplingX[i] > maxJPX) {
        maxJPX = h.jpegUpsamplingX[i];
      }
    }
    h.isSubsampled = maxJPX > 0 || maxJPY > 0;
    h.height = ceilDiv(h.height, 1 << maxJPY) << maxJPY;
    h.width = ceilDiv(h.width, 1 << maxJPX) << maxJPX;
    for (var i = 0; i < 3; i++) {
      h.jpegUpsamplingY[i] = maxJPY - h.jpegUpsamplingY[i];
      h.jpegUpsamplingX[i] = maxJPX - h.jpegUpsamplingX[i];
    }
    return h;
  }
}
