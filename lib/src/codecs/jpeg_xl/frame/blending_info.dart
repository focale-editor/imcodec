import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Per-channel blending parameters from the frame header.
final class BlendingInfo {
  /// Blending mode identifier defined by the JPEG XL specification.
  final int mode;

  /// Extra-channel index supplying alpha for blending.
  final int alphaChannel;

  /// Whether blended samples are clamped to the nominal range.
  final bool clamp;

  /// Reference-frame slot used as the blending source.
  final int source;

  /// Creates the replace-mode defaults used for a full frame.
  const BlendingInfo.defaults() : mode = FrameFlags.blendReplace, alphaChannel = 0, clamp = false, source = 0;

  /// Reads this structure from the bitstream.
  factory BlendingInfo.read({
    required BitReader reader,
    required bool extra,
    required bool coversFullCanvas,
  }) {
    final int mode = reader.readU32(0, 0, 1, 0, 2, 0, 3, 2);
    final int alphaChannel = extra && (mode == FrameFlags.blendBlend || mode == FrameFlags.blendMulAdd) ? reader.readU32(0, 0, 1, 0, 2, 0, 3, 3) : 0;
    final bool clamp = extra && (mode == FrameFlags.blendBlend || mode == FrameFlags.blendMultiply || mode == FrameFlags.blendMulAdd) && reader.readBool();
    final int source = mode != FrameFlags.blendReplace || !coversFullCanvas ? reader.readBits(2) : 0;
    return BlendingInfo._(mode: mode, alphaChannel: alphaChannel, clamp: clamp, source: source);
  }

  /// Creates decoded blending settings.
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
