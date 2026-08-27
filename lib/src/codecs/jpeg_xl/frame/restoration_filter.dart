import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/extensions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Gaborish + edge-preserving-filter parameters from the frame header.
final class RestorationFilter {
  /// Whether Gaborish deringing is enabled.
  bool usesGaborish = true;

  /// Whether custom Gaborish weights replace specification defaults.
  bool usesCustomGaborish = false;

  /// First-neighbor Gaborish weight for each color channel.
  final Float32List gab1Weights = Float32List.fromList(const [0.115169525, 0.115169525, 0.115169525]);

  /// Diagonal-neighbor Gaborish weight for each color channel.
  final Float32List gab2Weights = Float32List.fromList(const [0.061248592, 0.061248592, 0.061248592]);

  /// Number of edge-preserving filter passes.
  int epfIterations = 2;

  /// Whether a custom sharpness lookup table is encoded.
  bool epfSharpCustom = false;

  /// Sigma multiplier selected by the quantized sharpness value.
  final Float32List epfSharpLut = Float32List.fromList(const [0, 1 / 7, 2 / 7, 3 / 7, 4 / 7, 5 / 7, 6 / 7, 1]);

  /// Whether custom per-channel filter scales are encoded.
  bool epfWeightCustom = false;

  /// Edge-difference scale for each color channel.
  final Float32List epfChannelScale = Float32List.fromList(const [40.0, 5.0, 3.5]);

  /// Whether custom sigma parameters are encoded.
  bool epfSigmaCustom = false;

  /// Multiplier converting the quantization field to filter sigma.
  double epfQuantMul = 0.46;

  /// Sigma scale applied by the first filter pass.
  double epfPass0SigmaScale = 0.9;

  /// Sigma scale applied by the third filter pass.
  double epfPass2SigmaScale = 6.5;

  /// Border multiplier for the sum of absolute differences.
  double epfBorderSadMul = 2 / 3;

  /// Fixed sigma used for modular frames.
  double epfSigmaForModular = 1.0;

  /// Returns the extension payloads.
  Extensions extensions = const Extensions();

  /// Returns the specification defaults.
  RestorationFilter.defaults() {
    _bakeSharpLut();
  }

  /// Reads this structure from the bitstream.
  factory RestorationFilter.read({
    required BitReader reader,
    required int encoding,
  }) {
    final bool allDefault = reader.readBool();
    if (allDefault) {
      return RestorationFilter.defaults();
    }
    final rf = RestorationFilter._();
    rf.usesGaborish = reader.readBool();
    rf.usesCustomGaborish = rf.usesGaborish && reader.readBool();
    if (rf.usesCustomGaborish) {
      for (var i = 0; i < 3; i++) {
        rf.gab1Weights[i] = reader.readF16();
        rf.gab2Weights[i] = reader.readF16();
      }
    }
    rf.epfIterations = reader.readBits(2);
    rf.epfSharpCustom = rf.epfIterations > 0 && encoding == FrameFlags.vardct && reader.readBool();
    if (rf.epfSharpCustom) {
      for (var i = 0; i < 8; i++) {
        rf.epfSharpLut[i] = reader.readF16();
      }
    }
    rf.epfWeightCustom = rf.epfIterations > 0 && reader.readBool();
    if (rf.epfWeightCustom) {
      for (var i = 0; i < 3; i++) {
        rf.epfChannelScale[i] = reader.readF16();
      }
      reader.readBits(32);
    }
    rf.epfSigmaCustom = rf.epfIterations > 0 && reader.readBool();
    rf.epfQuantMul = rf.epfSigmaCustom && encoding == FrameFlags.vardct ? reader.readF16() : 0.46;
    rf.epfPass0SigmaScale = rf.epfSigmaCustom ? reader.readF16() : 0.9;
    rf.epfPass2SigmaScale = rf.epfSigmaCustom ? reader.readF16() : 6.5;
    rf.epfBorderSadMul = rf.epfSigmaCustom ? reader.readF16() : 2 / 3;
    rf.epfSigmaForModular = rf.epfIterations > 0 && encoding == FrameFlags.modular ? reader.readF16() : 1.0;
    rf.extensions = Extensions.read(reader: reader);
    rf._bakeSharpLut();
    return rf;
  }

  /// Creates a restoration filter.
  RestorationFilter._();

  /// Builds sharp lookup table.
  void _bakeSharpLut() {
    for (var i = 0; i < 8; i++) {
      epfSharpLut[i] *= epfQuantMul;
    }
  }
}
