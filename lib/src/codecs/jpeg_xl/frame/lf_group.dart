import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_metadata.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/lf_coefficients.dart';

/// One LF group: LF (DC) coefficients and HF metadata for VarDCT frames,
/// plus the modular sub-stream carrying squeezed global channels.
final class LfGroup {
  /// Stores the lf group iD value used while processing JPEG XL data.
  ///
  final int lfGroupID;

  /// LF group size in 8x8 blocks.
  late final int blockHeight;

  /// Stores the block width value used while processing JPEG XL data.
  ///
  late final int blockWidth;

  /// Stores the lf coeff value used while processing JPEG XL data.
  ///
  LfCoefficients? lfCoeff;

  /// Stores the modular lf group value used while processing JPEG XL data.
  ///
  late final ModularStream modularLfGroup;

  /// Stores the hf metadata value used while processing JPEG XL data.
  ///
  HfMetadata? hfMetadata;

  /// Creates Lf group data for JPEG XL processing.
  ///
  LfGroup({
    required BitReader reader,
    required Frame frame,
    required this.lfGroupID,
    required List<ModularChannel> replaced,
  }) {
    final ({int height, int width}) size = frame.lfGroupSize(lfGroupID);
    blockHeight = size.height >> 3;
    blockWidth = size.width >> 3;
    final isVarDCT = frame.header.encoding == FrameFlags.vardct;
    lfCoeff = isVarDCT ? LfCoefficients(reader: reader, parent: this, frame: frame) : null;
    modularLfGroup = ModularStream.read(reader: reader, ctx: frame.modularContext, streamIndex: 1 + frame.numLfGroups + lfGroupID, channelArray: replaced);
    modularLfGroup.decodeChannels(reader);
    hfMetadata = isVarDCT ? HfMetadata(reader: reader, parent: this, frame: frame) : null;
  }
}
