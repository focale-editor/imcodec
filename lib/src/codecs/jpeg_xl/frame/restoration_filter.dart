import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/extensions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Gaborish + edge-preserving-filter parameters from the frame header.
final class RestorationFilter {
  /// Stores the gab value used while processing JPEG XL data.
  ///
  bool gab = true;

  /// Stores the custom gab value used while processing JPEG XL data.
  ///
  bool customGab = false;

  /// Processes gab1 weights information in a JPEG XL codestream.
  ///
  final Float32List gab1Weights = Float32List.fromList(const [0.115169525, 0.115169525, 0.115169525]);

  /// Processes gab2 weights information in a JPEG XL codestream.
  ///
  final Float32List gab2Weights = Float32List.fromList(const [0.061248592, 0.061248592, 0.061248592]);

  /// Stores the epf iterations value used while processing JPEG XL data.
  ///
  int epfIterations = 2;

  /// Stores the epf sharp custom value used while processing JPEG XL data.
  ///
  bool epfSharpCustom = false;

  /// Processes epf sharp lut information in a JPEG XL codestream.
  ///
  final Float32List epfSharpLut = Float32List.fromList(const [0, 1 / 7, 2 / 7, 3 / 7, 4 / 7, 5 / 7, 6 / 7, 1]);

  /// Stores the epf weight custom value used while processing JPEG XL data.
  ///
  bool epfWeightCustom = false;

  /// Processes epf channel scale information in a JPEG XL codestream.
  ///
  final Float32List epfChannelScale = Float32List.fromList(const [40.0, 5.0, 3.5]);

  /// Stores the epf sigma custom value used while processing JPEG XL data.
  ///
  bool epfSigmaCustom = false;

  /// Stores the epf quant mul value used while processing JPEG XL data.
  ///
  double epfQuantMul = 0.46;

  /// Stores the epf pass0 sigma scale value used while processing JPEG XL data.
  ///
  double epfPass0SigmaScale = 0.9;

  /// Stores the epf pass2 sigma scale value used while processing JPEG XL data.
  ///
  double epfPass2SigmaScale = 6.5;

  /// Stores the epf border sad mul value used while processing JPEG XL data.
  ///
  double epfBorderSadMul = 2 / 3;

  /// Stores the epf sigma for modular value used while processing JPEG XL data.
  ///
  double epfSigmaForModular = 1.0;

  /// Processes extensions information in a JPEG XL codestream.
  ///
  Extensions extensions = const Extensions();

  /// Processes defaults information in a JPEG XL codestream.
  ///
  RestorationFilter.defaults() {
    _bakeSharpLut();
  }

  /// Processes read information in a JPEG XL codestream.
  ///
  factory RestorationFilter.read({
    required BitReader reader,
    required int encoding,
  }) {
    final bool allDefault = reader.readBool();
    if (allDefault) {
      return RestorationFilter.defaults();
    }
    final rf = RestorationFilter._();
    rf.gab = reader.readBool();
    rf.customGab = rf.gab && reader.readBool();
    if (rf.customGab) {
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

  /// Creates Restoration filter state for JPEG XL processing.
  ///
  RestorationFilter._();

  /// Processes the bake sharp lut data used by the JPEG XL codec.
  ///
  void _bakeSharpLut() {
    for (var i = 0; i < 8; i++) {
      epfSharpLut[i] *= epfQuantMul;
    }
  }
}
