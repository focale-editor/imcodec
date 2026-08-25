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
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl_limits.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/ma_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_block_context.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/lf_channel_correlation.dart';

/// The LfGlobal frame section: frame-wide features and the global modular
/// stream. (VarDCT-specific parts land with M5.)
final class LfGlobal {
  /// Stores the patches value used while processing JPEG XL data.
  ///
  final List<Patch> patches = [];

  /// Stores the noise parameters value used while processing JPEG XL data.
  ///
  List<double>? noiseParameters;

  /// Stores the splines value used while processing JPEG XL data.
  ///
  SplinesBundle? splines;

  /// Stores the lf dequant value used while processing JPEG XL data.
  ///
  final List<double> lfDequant = [1 / 4096, 1 / 512, 1 / 256];

  /// Stores the global scale value used while processing JPEG XL data.
  ///
  int globalScale = 0;

  /// Stores the quant lF value used while processing JPEG XL data.
  ///
  int quantLF = 0;

  /// Stores the scaled dequant value used while processing JPEG XL data.
  ///
  final List<double> scaledDequant = [0, 0, 0];

  /// Stores the hf block ctx value used while processing JPEG XL data.
  ///
  HfBlockContext? hfBlockCtx;

  /// Processes lf chan corr information in a JPEG XL codestream.
  ///
  LfChannelCorrelation lfChanCorr = const LfChannelCorrelation();

  /// Stores the global modular value used while processing JPEG XL data.
  ///
  late ModularStream globalModular;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory LfGlobal.read({
    required BitReader reader,
    required Frame frame,
  }) {
    final lf = LfGlobal._();
    final FrameHeader header = frame.header;
    final ImageHeader metadata = frame.globalMetadata;
    if (header.flags & FrameFlags.patches != 0) {
      final stream = EntropyStream.read(reader: reader, numDists: 10);
      final int numPatches = stream.readSymbol(reader, 0);
      if (numPatches > JpegXlLimits.maxFeatureCount) {
        throw const JpegXlInvalidBitstreamException(message: 'too many patches');
      }
      for (var i = 0; i < numPatches; i++) {
        lf.patches.add(Patch.read(stream: stream, reader: reader, extraChannelCount: metadata.extraChannels.length, alphaChannelCount: metadata.alphaIndices.length));
      }
      if (!stream.validateFinalState()) {
        throw const JpegXlInvalidBitstreamException(message: 'illegal patch entropy state');
      }
    }
    if (header.flags & FrameFlags.splines != 0) {
      lf.splines = SplinesBundle.read(reader: reader);
    }
    if (header.flags & FrameFlags.noise != 0) {
      if (metadata.colorChannelCount < 3) {
        throw const JpegXlInvalidBitstreamException(message: 'cannot do noise in grayscale');
      }
      lf.noiseParameters = List.generate(8, (_) => reader.readBits(10) / 1024.0);
    }
    if (!reader.readBool()) {
      for (var i = 0; i < 3; i++) {
        lf.lfDequant[i] = reader.readF16() * (1 / 128);
      }
    }
    if (header.encoding == FrameFlags.vardct) {
      lf.globalScale = reader.readU32(1, 11, 2049, 11, 4097, 12, 8193, 16);
      lf.quantLF = reader.readU32(16, 0, 1, 5, 1, 8, 1, 16);
      for (var i = 0; i < 3; i++) {
        lf.scaledDequant[i] = (1 << 16) * lf.lfDequant[i] / (lf.globalScale * lf.quantLF);
      }
      lf.hfBlockCtx = HfBlockContext.read(reader: reader);
      lf.lfChanCorr = LfChannelCorrelation.read(reader: reader);
    }

    final bool hasGlobalTree = reader.readBool();
    frame.globalTree = hasGlobalTree ? MaTree.read(reader: reader) : null;

    var ecStart = 0;
    if (header.encoding == FrameFlags.modular) {
      if (!header.doYCbCr && !metadata.xybEncoded && metadata.colorEncoding.colorEncoding == ColorFlags.ceGray) {
        ecStart = 1;
      } else {
        ecStart = 3;
      }
    }
    final int subModularChannelCount = metadata.extraChannels.length + ecStart;
    lf.globalModular = ModularStream.read(reader: reader, ctx: frame.modularContext, streamIndex: 0, channelCount: subModularChannelCount, ecStart: ecStart);
    lf.globalModular.decodeChannels(reader, partial: true);
    return lf;
  }

  /// Creates Lf global state for JPEG XL processing.
  ///
  LfGlobal._();
}
