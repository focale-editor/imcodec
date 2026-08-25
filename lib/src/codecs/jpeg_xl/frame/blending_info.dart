import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Per-channel blending parameters from the frame header.
final class BlendingInfo {
  /// Stores the mode value used while processing JPEG XL data.
  ///
  final int mode;

  /// Stores the alpha channel value used while processing JPEG XL data.
  ///
  final int alphaChannel;

  /// Stores the clamp value used while processing JPEG XL data.
  ///
  final bool clamp;

  /// Stores the source value used while processing JPEG XL data.
  ///
  final int source;

  /// Processes defaults information in a JPEG XL codestream.
  ///
  const BlendingInfo.defaults() : mode = FrameFlags.blendReplace, alphaChannel = 0, clamp = false, source = 0;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory BlendingInfo.read({
    required BitReader reader,
    required bool extra,
    required bool fullFrame,
  }) {
    final int mode = reader.readU32(0, 0, 1, 0, 2, 0, 3, 2);
    final int alphaChannel = extra && (mode == FrameFlags.blendBlend || mode == FrameFlags.blendMulAdd) ? reader.readU32(0, 0, 1, 0, 2, 0, 3, 3) : 0;
    final bool clamp = extra && (mode == FrameFlags.blendBlend || mode == FrameFlags.blendMult || mode == FrameFlags.blendMulAdd) && reader.readBool();
    final int source = mode != FrameFlags.blendReplace || !fullFrame ? reader.readBits(2) : 0;
    return BlendingInfo._(mode: mode, alphaChannel: alphaChannel, clamp: clamp, source: source);
  }

  /// Creates Blending info state for JPEG XL processing.
  ///
  const BlendingInfo._({
    required this.mode,
    required this.alphaChannel,
    required this.clamp,
    required this.source,
  });

  /// Direct construction (used by patches).
  const BlendingInfo.raw({
    required this.mode,
    required this.alphaChannel,
    required this.clamp,
    required this.source,
  });
}
