import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_metadata.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/low_frequency_coefficients.dart';

/// Holds one low-frequency group and its associated VarDCT metadata.
/// The modular substream also carries squeezed global channels.
final class LowFrequencyGroup {
  /// Identifier of this group within its frame.
  final int lowFrequencyGroupId;

  /// Group height measured in 8 × 8 blocks.
  late final int blockHeight;

  /// Group width measured in 8 × 8 blocks.
  late final int blockWidth;

  /// Decoded low-frequency coefficients for VarDCT frames.
  LowFrequencyCoefficients? lowFrequencyCoefficients;

  /// Modular substream carrying this group's channels.
  late final ModularStream modularStream;

  /// Block metadata required to decode high-frequency coefficients.
  HighFrequencyMetadata? highFrequencyMetadata;

  /// Creates a low-frequency group.
  LowFrequencyGroup({
    required BitReader reader,
    required Frame frame,
    required this.lowFrequencyGroupId,
    required List<ModularChannel> replaced,
  }) {
    final ({int height, int width}) size = frame.lowFrequencyGroupSize(lowFrequencyGroupId);
    blockHeight = size.height >> 3;
    blockWidth = size.width >> 3;
    final bool isVarDct = frame.header.encoding == FrameFlags.vardct;
    lowFrequencyCoefficients = isVarDct ? LowFrequencyCoefficients(reader: reader, parent: this, frame: frame) : null;
    modularStream = ModularStream.read(reader: reader, context: frame.modularContext, streamIndex: 1 + frame.lowFrequencyGroupCount + lowFrequencyGroupId, channelArray: replaced);
    modularStream.decodeChannels(reader);
    highFrequencyMetadata = isVarDct ? HighFrequencyMetadata(reader: reader, parent: this, frame: frame) : null;
  }
}
