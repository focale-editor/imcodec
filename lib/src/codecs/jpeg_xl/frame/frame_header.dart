import 'dart:convert';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/blending_info.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/progressive_passes.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/restoration_filter.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/extensions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The frame header bundle, including the resolved frame bounds.
final class FrameHeader {
  /// Full-resolution coding-group dimension in pixels.
  int groupDimension = 256;

  /// Optional frame-header extension payloads.
    Extensions extensions = const Extensions();

  /// Type identifier defined by the JPEG XL specification.
    int type = FrameFlags.regularFrame;

  /// Encoding identifier for the frame header.
    int encoding = FrameFlags.vardct;

  /// Bit flags defined for the frame header.
    int flags = 0;

  /// Whether color channels are represented as YCbCr.
    bool usesYcbcr = false;

  /// Vertical JPEG subsampling shift for each color channel.
    final List<int> jpegVerticalUpsamplingShift = [0, 0, 0];

  /// Horizontal JPEG subsampling shift for each color channel.
    final List<int> jpegHorizontalUpsamplingShift = [0, 0, 0];

  /// Upsampling factor applied to color channels.
    int upsampling = 1;

  /// Upsampling factor for each extra channel.
    List<int> extraChannelUpsampling = const [];

  /// Exponent selecting the coding-group dimension.
    int groupSizeShift = 1;

  /// Restoration filters applied after frame reconstruction.
    RestorationFilter restorationFilter = RestorationFilter.defaults();

  /// Low-frequency group dimension in pixels.
    int lowFrequencyGroupDimension = 2048;

  /// Base-two logarithm of [groupDimension].
    int logGroupDimension = 8;

  /// Base-two logarithm of [lowFrequencyGroupDimension].
    int logLowFrequencyGroupDimension = 11;

  /// Quantization scale for the opsin X channel.
    int xQuantizationScale = 2;

  /// Quantization scale for the opsin B channel.
    int bQuantizationScale = 2;

  /// Progressive-pass configuration for this frame.
    ProgressivePasses passes = ProgressivePasses.defaults();

  /// Progressive low-frequency frame level.
    int lowFrequencyLevel = 0;

  /// Whether explicit frame bounds are encoded.
    bool hasCrop = false;

  /// Horizontal origin of the decoded frame bounds.
    /// The origin can be negative; width and height are the decoded
  /// frame size (after the upsampling/lowFrequencyLevel adjustments).
  int x0 = 0;

  /// Vertical origin of the frame crop.
    int y0 = 0;

  /// Width in pixels.
    int width = 0;

  /// Whether any JPEG color channel is subsampled.
    bool isSubsampled = false;

  /// Whether the decoded bounds cover the complete image canvas.
    bool coversFullCanvas = true;

  /// Blending settings for the color channels.
    BlendingInfo blendingInfo = const BlendingInfo.defaults();

  /// Blending settings for each extra channel.
    List<BlendingInfo> ecBlendingInfo = const [];

  /// Frame duration in animation ticks.
    int duration = 0;

  /// Presentation timecode carried by the frame.
    int timecode = 0;

  /// Whether this is the last frame.
    bool isLast = true;

  /// Reference-frame slot receiving this frame.
    int referenceSlot = 0;

  /// Whether the reference frame is saved before color transforms.
    bool saveBeforeColorTransform = false;

  /// Name carried by the codestream.
    String name = '';

  /// Height in pixels.
    int height = 0;

  /// Creates a frame header with specification defaults.
    FrameHeader._();

  /// Reads this structure from the bitstream.
    factory FrameHeader.read({
    required BitReader reader,
    required ImageHeader parent,
  }) {
    final h = FrameHeader._();
    final bool allDefault = reader.readBool();
    h.type = allDefault ? FrameFlags.regularFrame : reader.readBits(2);
    h.encoding = allDefault ? FrameFlags.vardct : reader.readBits(1);
    h.flags = allDefault ? 0 : reader.readU64();
    h.usesYcbcr = !allDefault && !parent.xybEncoded && reader.readBool();
    if (h.usesYcbcr && h.flags & FrameFlags.useLfFrame == 0) {
      for (var i = 0; i < 3; i++) {
        final int mode = reader.readBits(2);
        switch (mode) {
          case 1:
            h.jpegVerticalUpsamplingShift[i] = 1;
            h.jpegHorizontalUpsamplingShift[i] = 1;
          case 2:
            h.jpegVerticalUpsamplingShift[i] = 0;
            h.jpegHorizontalUpsamplingShift[i] = 1;
          case 3:
            h.jpegVerticalUpsamplingShift[i] = 1;
            h.jpegHorizontalUpsamplingShift[i] = 0;
        }
      }
    }
    h.extraChannelUpsampling = List<int>.filled(parent.extraChannels.length, 1);
    if (!allDefault && h.flags & FrameFlags.useLfFrame == 0) {
      h.upsampling = 1 << reader.readBits(2);
      for (var i = 0; i < h.extraChannelUpsampling.length; i++) {
        h.extraChannelUpsampling[i] = 1 << reader.readBits(2);
      }
    } else {
      h.upsampling = 1;
    }
    h.groupSizeShift = h.encoding == FrameFlags.modular ? reader.readBits(2) : 1;
    h.groupDimension = 128 << h.groupSizeShift;
    h.lowFrequencyGroupDimension = h.groupDimension << 3;
    h.logGroupDimension = ceilLog2(h.groupDimension);
    h.logLowFrequencyGroupDimension = ceilLog2(h.lowFrequencyGroupDimension);
    if (parent.xybEncoded && h.encoding == FrameFlags.vardct) {
      h.xQuantizationScale = allDefault ? 3 : reader.readBits(3);
      h.bQuantizationScale = allDefault ? 2 : reader.readBits(3);
    } else {
      h.xQuantizationScale = 2;
      h.bQuantizationScale = 2;
    }
    h.passes = !allDefault && h.type != FrameFlags.referenceOnly ? ProgressivePasses.read(reader: reader) : ProgressivePasses.defaults();
    h.lowFrequencyLevel = h.type == FrameFlags.lowFrequencyFrame ? 1 + reader.readBits(2) : 0;
    h.hasCrop = !allDefault && h.type != FrameFlags.lowFrequencyFrame && reader.readBool();
    final int imageWidth = parent.size.width;
    final int imageHeight = parent.size.height;
    if (h.hasCrop && h.type != FrameFlags.referenceOnly) {
      final int x0 = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      final int y0 = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      h.x0 = unpackSigned(x0);
      h.y0 = unpackSigned(y0);
    }
    if (h.hasCrop) {
      h.width = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      h.height = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
    } else {
      h.width = imageWidth;
      h.height = imageHeight;
    }
    final bool normalFrame = !allDefault && (h.type == FrameFlags.regularFrame || h.type == FrameFlags.skipProgressive);
    // Computed before the upsampling/lowFrequencyLevel divisions, intentionally.
    final bool coversFullCanvas = h.y0 <= 0 && h.x0 <= 0 && h.height + h.y0 >= imageHeight && h.width + h.x0 >= imageWidth;
    h.coversFullCanvas = coversFullCanvas;
    h.height = ceilDiv(h.height, h.upsampling);
    h.width = ceilDiv(h.width, h.upsampling);
    h.height = ceilDiv(h.height, 1 << (3 * h.lowFrequencyLevel));
    h.width = ceilDiv(h.width, 1 << (3 * h.lowFrequencyLevel));
    h.ecBlendingInfo = List<BlendingInfo>.filled(parent.extraChannels.length, const BlendingInfo.defaults());
    if (normalFrame) {
      h.blendingInfo = BlendingInfo.read(reader: reader, extra: h.ecBlendingInfo.isNotEmpty, coversFullCanvas: coversFullCanvas);
      for (var i = 0; i < h.ecBlendingInfo.length; i++) {
        h.ecBlendingInfo[i] = BlendingInfo.read(reader: reader, extra: true, coversFullCanvas: coversFullCanvas);
      }
    } else {
      h.blendingInfo = const BlendingInfo.defaults();
    }
    final animated = parent.animation != null;
    h.duration = normalFrame && animated ? reader.readU32(0, 0, 1, 0, 0, 8, 0, 32) : 0;
    h.timecode = normalFrame && animated && parent.animation!.hasTimecodes ? reader.readBits(32) : 0;
    h.isLast = normalFrame ? reader.readBool() : h.type == FrameFlags.regularFrame;
    h.referenceSlot = !allDefault && h.type != FrameFlags.lowFrequencyFrame && !h.isLast ? reader.readBits(2) : 0;
    h.saveBeforeColorTransform =
        !allDefault &&
        (h.type == FrameFlags.referenceOnly ||
            coversFullCanvas &&
                (h.type == FrameFlags.regularFrame || h.type == FrameFlags.skipProgressive) &&
                (h.duration == 0 || h.referenceSlot != 0) &&
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
      if (h.jpegVerticalUpsamplingShift[i] > maxJPY) {
        maxJPY = h.jpegVerticalUpsamplingShift[i];
      }
      if (h.jpegHorizontalUpsamplingShift[i] > maxJPX) {
        maxJPX = h.jpegHorizontalUpsamplingShift[i];
      }
    }
    h.isSubsampled = maxJPX > 0 || maxJPY > 0;
    h.height = ceilDiv(h.height, 1 << maxJPY) << maxJPY;
    h.width = ceilDiv(h.width, 1 << maxJPX) << maxJPX;
    for (var i = 0; i < 3; i++) {
      h.jpegVerticalUpsamplingShift[i] = maxJPY - h.jpegVerticalUpsamplingShift[i];
      h.jpegHorizontalUpsamplingShift[i] = maxJPX - h.jpegHorizontalUpsamplingShift[i];
    }
    return h;
  }
}
