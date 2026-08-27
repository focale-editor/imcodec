import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/patches.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/splines.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/limits.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/meta_adaptive_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_block_context.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/low_frequency_channel_correlation.dart';

/// Holds frame-wide low-frequency features and the global modular stream.
final class LowFrequencyGlobal {
  /// Patches applied while rendering the frame.
  final List<Patch> patches = [];

  /// Parameters for synthetic film-grain noise, when enabled.
  List<double>? noiseParameters;

  /// Splines rendered into the frame, when present.
  SplinesBundle? splines;

  /// Base dequantization factors for the three color channels.
  final List<double> lowFrequencyDequantization = [1 / 4096, 1 / 512, 1 / 256];

  /// Global quantization scale read for VarDCT frames.
  int globalScale = 0;

  /// Quantization factor applied to low-frequency coefficients.
  int lowFrequencyQuantization = 0;

  /// Effective dequantization factor for each color channel.
  final List<double> scaledDequantization = [0, 0, 0];

  /// Context model used by high-frequency coefficient blocks.
  HighFrequencyBlockContext? highFrequencyBlockContext;

  /// Chroma-from-luma correlation parameters.
  LowFrequencyChannelCorrelation lowFrequencyChannelCorrelation = const LowFrequencyChannelCorrelation();

  /// Global modular stream shared by the frame sections.
  late ModularStream globalModularStream;

  /// Reads the global low-frequency section from [reader].
  factory LowFrequencyGlobal.read({
    required BitReader reader,
    required Frame frame,
  }) {
    final LowFrequencyGlobal lowFrequencyGlobal = LowFrequencyGlobal._();
    final FrameHeader header = frame.header;
    final ImageHeader metadata = frame.globalMetadata;
    if (header.flags & FrameFlags.patches != 0) {
      final stream = EntropyStream.read(reader: reader, distributionCount: 10);
      final int numPatches = stream.readSymbol(reader, 0);
      if (numPatches > JpegXlLimits.maxFeatureCount) {
        throw const JpegXlInvalidBitstreamException(message: 'too many patches');
      }
      for (var i = 0; i < numPatches; i++) {
        lowFrequencyGlobal.patches.add(Patch.read(stream: stream, reader: reader, extraChannelCount: metadata.extraChannels.length, alphaChannelCount: metadata.alphaIndices.length));
      }
      if (!stream.validateFinalState()) {
        throw const JpegXlInvalidBitstreamException(message: 'illegal patch entropy state');
      }
    }
    if (header.flags & FrameFlags.splines != 0) {
      lowFrequencyGlobal.splines = SplinesBundle.read(reader: reader);
    }
    if (header.flags & FrameFlags.noise != 0) {
      if (metadata.colorChannelCount < 3) {
        throw const JpegXlInvalidBitstreamException(message: 'cannot do noise in grayscale');
      }
      lowFrequencyGlobal.noiseParameters = List.generate(8, (_) => reader.readBits(10) / 1024.0);
    }
    if (!reader.readBool()) {
      for (var i = 0; i < 3; i++) {
        lowFrequencyGlobal.lowFrequencyDequantization[i] = reader.readF16() * (1 / 128);
      }
    }
    if (header.encoding == FrameFlags.vardct) {
      lowFrequencyGlobal.globalScale = reader.readU32(1, 11, 2049, 11, 4097, 12, 8193, 16);
      lowFrequencyGlobal.lowFrequencyQuantization = reader.readU32(16, 0, 1, 5, 1, 8, 1, 16);
      for (var i = 0; i < 3; i++) {
        lowFrequencyGlobal.scaledDequantization[i] = (1 << 16) * lowFrequencyGlobal.lowFrequencyDequantization[i] / (lowFrequencyGlobal.globalScale * lowFrequencyGlobal.lowFrequencyQuantization);
      }
      lowFrequencyGlobal.highFrequencyBlockContext = HighFrequencyBlockContext.read(reader: reader);
      lowFrequencyGlobal.lowFrequencyChannelCorrelation = LowFrequencyChannelCorrelation.read(reader: reader);
    }

    final bool hasGlobalTree = reader.readBool();
    frame.globalTree = hasGlobalTree ? MetaAdaptiveTree.read(reader: reader) : null;

    var ecStart = 0;
    if (header.encoding == FrameFlags.modular) {
      if (!header.usesYcbcr && !metadata.xybEncoded && metadata.colorEncoding.colorEncoding == ColorEncodingConstants.colorSpaceGray) {
        ecStart = 1;
      } else {
        ecStart = 3;
      }
    }
    final int subModularChannelCount = metadata.extraChannels.length + ecStart;
    lowFrequencyGlobal.globalModularStream = ModularStream.read(reader: reader, context: frame.modularContext, streamIndex: 0, channelCount: subModularChannelCount, ecStart: ecStart);
    lowFrequencyGlobal.globalModularStream.decodeChannels(reader, partial: true);
    return lowFrequencyGlobal;
  }

  /// Creates an empty global section while it is being decoded.
  LowFrequencyGlobal._();
}
