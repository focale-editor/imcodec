import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/lf_global.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/lf_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/passes_info.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/toc.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg/jpeg_coeff_sink.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/ma_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/render/filters.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_coefficients.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_global.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/hf_pass.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/var_dct_inverter.dart';

/// XYB channel remap: X, Y, B are stored as Y, X, (B - Y) in modular and
/// decode order Y, X, B in VarDCT.
const cMap = [1, 0, 2];

/// Per-pass metadata: which not-yet-decoded global modular channels this
/// pass carries, plus the VarDCT HFPass data.
final class Pass {
  /// Stores the max shift value used while processing JPEG XL data.
  ///
  final int maxShift;

  /// Stores the min shift value used while processing JPEG XL data.
  ///
  late final int minShift;

  /// Stores the replaced channels value used while processing JPEG XL data.
  ///
  late final List<ModularChannel?> replacedChannels;

  /// Stores the hf pass value used while processing JPEG XL data.
  ///
  HfPass? hfPass;

  /// Creates Pass data for JPEG XL processing.
  ///
  Pass({
    required BitReader reader,
    required Frame frame,
    required int passIndex,
    required int prevMinShift,
  }) : maxShift = passIndex > 0 ? prevMinShift : 3 {
    final PassesInfo passes = frame.header.passes;
    var n = -1;
    for (var i = 0; i < passes.lastPass.length; i++) {
      if (passes.lastPass[i] == passIndex) {
        n = i;
        break;
      }
    }
    minShift = n >= 0 ? ceilLog1p(passes.downSample[n] - 1) : maxShift;
    final ModularStream stream = frame.lfGlobal.globalModular;
    replacedChannels = List<ModularChannel?>.filled(stream.encodedChannelCount, null);
    for (var i = 0; i < replacedChannels.length; i++) {
      final ModularChannel chan = stream.getChannel(i);
      if (!chan.decoded) {
        final int m = chan.vshift < chan.hshift ? chan.vshift : chan.hshift;
        if (minShift <= m && m < maxShift) {
          replacedChannels[i] = ModularChannel.copy(other: chan);
        }
      }
    }
    hfPass = frame.header.encoding == FrameFlags.vardct ? HfPass(reader: reader, frame: frame, passIndex: passIndex) : null;
  }
}

/// One frame of the codestream: header, TOC, and the decode orchestration
/// across LF groups, passes and pass groups (modular and VarDCT).
final class Frame {
  /// Stores the num groups value used while processing JPEG XL data.
  ///
  int numGroups = 0;

  /// Stores the global reader value used while processing JPEG XL data.
  ///
  final BitReader globalReader;

  /// Stores the global metadata value used while processing JPEG XL data.
  ///
  final ImageHeader globalMetadata;

  /// Stores the header value used while processing JPEG XL data.
  ///
  late FrameHeader header;

  /// Stores the toc value used while processing JPEG XL data.
  ///
  late Toc toc;

  /// Stores the lf global value used while processing JPEG XL data.
  ///
  late LfGlobal lfGlobal;

  /// Stores the global tree value used while processing JPEG XL data.
  ///
  MaTree? globalTree;

  /// Stores the hf global value used while processing JPEG XL data.
  ///
  HfGlobal? hfGlobal;

  /// Stores the passes value used while processing JPEG XL data.
  ///
  List<Pass> passes = [];

  /// Stores the lf groups value used while processing JPEG XL data.
  ///
  List<LfGroup?> lfGroups = [];

  /// Horizontal origin of the mutable frame bounds.
  int boundsX0 = 0;

  /// Vertical origin of the mutable frame bounds.
  int boundsY0 = 0;

  /// Width of the mutable frame bounds.
  int boundsWidth = 0;

  /// Height of the mutable frame bounds.
  int boundsHeight = 0;

  /// Stores the num lf groups value used while processing JPEG XL data.
  ///
  int numLfGroups = 0;

  /// Stores the group row stride value used while processing JPEG XL data.
  ///
  int groupRowStride = 0;

  /// Stores the lf group row stride value used while processing JPEG XL data.
  ///
  int lfGroupRowStride = 0;

  /// Per-channel frame output, sized to the padded frame size.
  late List<ImageBuffer> buffer;

  /// When set (JPEG reconstruction), the decode captures quantized DC/AC
  /// coefficients into [jpegSink] via gated hooks in Lf/HfCoefficients.
  bool captureJpeg = false;

  /// Stores the jpeg sink value used while processing JPEG XL data.
  ///
  JpegCoeffSink? jpegSink;

  /// When set, the modular pass-group sections (the large, full-resolution
  /// Squeeze residual channels) are skipped: their target channels are
  /// zero-allocated instead of decoded, so the inverse Squeeze upsamples the
  /// low-frequency pyramid with zero high-frequency detail. Only meaningful
  /// for a Squeeze (responsive) modular frame, where it yields a ~1:8-accurate
  /// image for a fraction of the decode cost — see the decoder's
  /// `_modularLowResImageFor` and doc/spec_notes.md's "Downscaled decode".
  bool modularLowRes = false;

  /// The LF frame's channel buffers when this frame uses one
  /// (`FrameFlags.useLfFrame`).
  List<ImageBuffer>? lfFrame;

  /// Creates Frame data for JPEG XL processing.
  ///
  Frame({
    required this.globalReader,
    required this.globalMetadata,
  });

  /// Number of TOC entries for this frame's structure.
  int get tocEntryCount {
    if (numGroups == 1 && header.passes.numPasses == 1) {
      return 1;
    }
    // lfGlobal + one per LF group + hfGlobal + one per pass per group.
    return 1 + numLfGroups + 1 + numGroups * header.passes.numPasses;
  }

  /// Number of color channels in the frame representation (not the output).
  int get colorChannelCount => globalMetadata.xybEncoded || header.encoding == FrameFlags.vardct ? 3 : globalMetadata.colorChannelCount;

  /// Processes padded frame size information in a JPEG XL codestream.
  ///
  ({int width, int height}) get paddedFrameSize {
    var factorY = 0;
    var factorX = 0;
    for (var i = 0; i < 3; i++) {
      if (header.jpegUpsamplingY[i] > factorY) {
        factorY = header.jpegUpsamplingY[i];
      }
      if (header.jpegUpsamplingX[i] > factorX) {
        factorX = header.jpegUpsamplingX[i];
      }
    }
    int height = boundsHeight;
    int width = boundsWidth;
    if (header.encoding == FrameFlags.vardct) {
      height = (height + 7) >> 3;
      width = (width + 7) >> 3;
    }
    height = ceilDiv(height, 1 << factorY);
    width = ceilDiv(width, 1 << factorX);
    if (header.encoding == FrameFlags.vardct) {
      return (width: (width << factorX) << 3, height: (height << factorY) << 3);
    }
    return (width: width << factorX, height: height << factorY);
  }

  /// Allocates [jpegSink], one entry per color channel (capture is keyed by
  /// JPEG component: DC channel `j` and AC channel `cMap[j]`). Component `j`'s
  /// block grid follows the subsampling of its governing JXL channel.
  void _allocJpegSink() {
    final ({int height, int width}) padded = paddedFrameSize;
    final int lumaWib = padded.width >> 3;
    final int lumaHib = padded.height >> 3;
    final wib = <int>[];
    final hib = <int>[];
    for (var j = 0; j < 3; j++) {
      wib.add(lumaWib >> header.jpegUpsamplingX[cMap[j]]);
      hib.add(lumaHib >> header.jpegUpsamplingY[cMap[j]]);
    }
    jpegSink = JpegCoeffSink(widthInBlocks: wib, heightInBlocks: hib);
  }

  /// Processes modular context information in a JPEG XL codestream.
  ///
  ModularFrameContext get modularContext => ModularFrameContext(
    frameWidth: boundsWidth,
    frameHeight: boundsHeight,
    groupDim: header.groupDim,
    globalTree: globalTree,
    ecDimShifts: [for (final ec in globalMetadata.extraChannels) ec.dimShift],
    bitDepth: globalMetadata.bitDepth.bitsPerSample,
  );

  /// Copies out modular.
  ///
  void _copyOutModular() {
    final List<ModularChannel> channels = lfGlobal.globalModular.channels;
    final int colors = colorChannelCount;
    for (var c = 0; c < channels.length; c++) {
      final bool isModularColor = header.encoding == FrameFlags.modular && c < colors;
      final bool isModularXYB = globalMetadata.xybEncoded && isModularColor;
      // X, Y, B is encoded as Y, X, (B - Y).
      final int cOut = (isModularXYB ? cMap[c] : c) + buffer.length - channels.length;
      final Int32List src = channels[c].buffer!;
      final int srcWidth = channels[c].width;
      if (isModularXYB && c == 2) {
        final List<Float32List> out = buffer[cOut].floatRows;
        final double scaleFactor = lfGlobal.lfDequant[cOut];
        final Int32List srcY = channels[0].buffer!;
        for (var y = 0; y < boundsHeight; y++) {
          final Float32List row = out[y];
          for (var x = 0; x < boundsWidth; x++) {
            row[x] = scaleFactor * (srcY[y * srcWidth + x] + src[y * srcWidth + x]);
          }
        }
      } else if (buffer[cOut].isFloat) {
        final List<Float32List> out = buffer[cOut].floatRows;
        final double scaleFactor = isModularXYB ? lfGlobal.lfDequant[cOut] : 1.0;
        for (var y = 0; y < boundsHeight; y++) {
          final Float32List row = out[y];
          for (var x = 0; x < boundsWidth; x++) {
            row[x] = scaleFactor * src[y * srcWidth + x];
          }
        }
      } else {
        final List<Int32List> out = buffer[cOut].intRows;
        for (var y = 0; y < boundsHeight; y++) {
          out[y].setRange(0, boundsWidth, src, y * srcWidth);
        }
      }
    }
  }

  /// Processes get group location information in a JPEG XL codestream.
  ///
  ({int y, int x}) getGroupLocation(int groupID) => (y: groupID ~/ groupRowStride, x: groupID % groupRowStride);

  /// Processes get lFGroup location information in a JPEG XL codestream.
  ///
  ({int y, int x}) getLFGroupLocation(int lfGroupID) => (y: lfGroupID ~/ lfGroupRowStride, x: lfGroupID % lfGroupRowStride);

  /// Position of this group within its LF group, in group units.
  ({int y, int x}) groupPosInLFGroup(int lfGroupID, int groupID) {
    final ({int x, int y}) gr = getGroupLocation(groupID);
    final ({int x, int y}) lf = getLFGroupLocation(lfGroupID);
    return (y: gr.y - (lf.y << 3), x: gr.x - (lf.x << 3));
  }

  /// Processes get lFGroup for group information in a JPEG XL codestream.
  ///
  LfGroup getLFGroupForGroup(int groupID) {
    final ({int x, int y}) pos = getGroupLocation(groupID);
    return lfGroups[(pos.y >> 3) * lfGroupRowStride + (pos.x >> 3)]!;
  }

  /// Processes group size information in a JPEG XL codestream.
  ///
  ({int height, int width}) groupSize(int groupID) {
    final ({int x, int y}) pos = getGroupLocation(groupID);
    final ({int height, int width}) padded = paddedFrameSize;
    final int height = header.groupDim < padded.height - pos.y * header.groupDim ? header.groupDim : padded.height - pos.y * header.groupDim;
    final int width = header.groupDim < padded.width - pos.x * header.groupDim ? header.groupDim : padded.width - pos.x * header.groupDim;
    return (height: height, width: width);
  }

  /// Processes lf group size information in a JPEG XL codestream.
  ///
  ({int height, int width}) lfGroupSize(int lfGroupID) {
    final ({int x, int y}) pos = getLFGroupLocation(lfGroupID);
    final ({int height, int width}) padded = paddedFrameSize;
    final int height = header.lfGroupDim < padded.height - pos.y * header.lfGroupDim ? header.lfGroupDim : padded.height - pos.y * header.lfGroupDim;
    final int width = header.lfGroupDim < padded.width - pos.x * header.lfGroupDim ? header.lfGroupDim : padded.width - pos.x * header.lfGroupDim;
    return (height: height, width: width);
  }

  /// Processes read toc information in a JPEG XL codestream.
  ///
  void readToc({bool allowTruncated = false}) {
    if (tocEntryCount > 1 << 20) {
      throw const JpegXlInvalidBitstreamException(message: 'too many TOC sections');
    }
    toc = Toc.read(reader: globalReader, tocEntries: tocEntryCount, allowTruncated: allowTruncated);
  }

  /// Streaming preview: decodes only LfGlobal and the LF groups (the DC
  /// image for VarDCT frames). Requires those TOC sections to be present.
  void decodeLfOnly() {
    lfGlobal = LfGlobal.read(reader: toc.sectionReader(0), frame: this);
    _decodeLfGroups();
  }

  /// Processes read frame header information in a JPEG XL codestream.
  ///
  FrameHeader readFrameHeader() {
    globalReader.zeroPadToByte();
    header = FrameHeader.read(reader: globalReader, parent: globalMetadata);
    boundsX0 = header.x0;
    boundsY0 = header.y0;
    boundsWidth = header.width;
    boundsHeight = header.height;
    groupRowStride = ceilDiv(boundsWidth, header.groupDim);
    lfGroupRowStride = ceilDiv(boundsWidth, header.groupDim << 3);
    numGroups = groupRowStride * ceilDiv(boundsHeight, header.groupDim);
    numLfGroups = lfGroupRowStride * ceilDiv(boundsHeight, header.groupDim << 3);
    return header;
  }

  /// Processes decode frame information in a JPEG XL codestream.
  ///
  void decodeFrame({List<ImageBuffer>? lfFrame, bool modularLowRes = false}) {
    this.lfFrame = lfFrame;
    this.modularLowRes = modularLowRes;
    const timings = bool.fromEnvironment('jxl.timings');
    final Stopwatch? sw = timings ? (Stopwatch()..start()) : null;
    void mark(String label) {
      if (sw != null) {
        // ignore: avoid_print
        print('  $label: ${sw.elapsedMilliseconds} ms');
        sw.reset();
      }
    }

    final isVarDCT = header.encoding == FrameFlags.vardct;
    lfGlobal = LfGlobal.read(reader: toc.sectionReader(0), frame: this);
    mark('lfGlobal');
    // Low-res Squeeze decode is only valid for a responsive frame (its
    // pass-group channels are high-frequency residuals). For a non-Squeeze
    // modular frame, bail right after the cheap LfGlobal read — before any
    // LF-group/assembly work — so the caller (`_modularLowResImageFor`) sees
    // `!usesSqueeze` and falls back to a full decode with minimal waste.
    if (modularLowRes && !isVarDCT && !lfGlobal.globalModular.usesSqueeze) {
      return;
    }
    final ({int height, int width}) padded = paddedFrameSize;
    final int colors = colorChannelCount;
    final int channelCount = colors + globalMetadata.extraChannels.length;
    buffer = [
      for (var c = 0; c < channelCount; c++)
        if (c < colors && (globalMetadata.xybEncoded || isVarDCT))
          ImageBuffer.float32(height: c < 3 ? padded.height >> header.jpegUpsamplingY[c] : padded.height, width: c < 3 ? padded.width >> header.jpegUpsamplingX[c] : padded.width)
        else
          ImageBuffer.int32(height: padded.height, width: padded.width),
    ];

    _decodeLfGroups();
    mark('lfGroups');

    final BitReader hfGlobalReader = toc.sectionReader(1 + numLfGroups);
    if (isVarDCT) {
      hfGlobal = HfGlobal(reader: hfGlobalReader, frame: this);
    }
    passes = [];
    for (var i = 0; i < header.passes.numPasses; i++) {
      passes.add(Pass(reader: hfGlobalReader, frame: this, passIndex: i, prevMinShift: i > 0 ? passes[i - 1].minShift : 0));
    }

    mark('hfGlobal+passes');
    _decodePassGroups();
    mark('passGroups');

    lfGlobal.globalModular.applyTransforms();
    _copyOutModular();
    mark('transforms+copyOut');

    _invertSubsampling();
    if (header.restorationFilter.gab) {
      performGabConvolution(this, colors);
      mark('gaborish');
    }
    if (header.restorationFilter.epfIterations > 0) {
      performEdgePreservingFilter(this, colors);
      mark('epf');
    }
  }

  /// Inverts JPEG-style chroma subsampling by repeatedly doubling the
  /// subsampled color planes with a [0.25, 0.75] filter.
  ///
  /// Neighbor taps mirror at the *visible* subsampled extent, matching
  /// libjxl's render pipeline: the padded DCT rows/columns beyond
  /// ceil(visible / 2) are never read. (jxlatte reads the padded samples
  /// instead, which shifts the final visible row on 4:2:0 images whose
  /// height is not a block multiple.)
  void _invertSubsampling() {
    for (var c = 0; c < 3; c++) {
      int xShift = header.jpegUpsamplingX[c];
      while (xShift-- > 0) {
        final int visIn = ceilDiv(boundsWidth, 1 << (xShift + 1));
        final ImageBuffer old = buffer[c]..castToFloat(globalMetadata.bitDepth.bitsPerSample);
        final List<Float32List> oldRows = old.floatRows;
        final newBuffer = ImageBuffer.float32(height: old.height, width: old.width * 2);
        final List<Float32List> newRows = newBuffer.floatRows;
        for (var y = 0; y < old.height; y++) {
          final Float32List oldRow = oldRows[y];
          final Float32List newRow = newRows[y];
          for (var x = 0; x < oldRow.length; x++) {
            final double b75 = 0.75 * oldRow[x];
            newRow[2 * x] = b75 + 0.25 * oldRow[x == 0 ? 0 : x - 1];
            newRow[2 * x + 1] = b75 + 0.25 * oldRow[x + 1 >= visIn ? visIn - 1 : x + 1];
          }
        }
        buffer[c] = newBuffer;
      }
      int yShift = header.jpegUpsamplingY[c];
      while (yShift-- > 0) {
        final int visIn = ceilDiv(boundsHeight, 1 << (yShift + 1));
        final ImageBuffer old = buffer[c]..castToFloat(globalMetadata.bitDepth.bitsPerSample);
        final List<Float32List> oldRows = old.floatRows;
        final newBuffer = ImageBuffer.float32(height: old.height * 2, width: old.width);
        final List<Float32List> newRows = newBuffer.floatRows;
        for (var y = 0; y < old.height; y++) {
          final Float32List oldRow = oldRows[y];
          final Float32List prevRow = oldRows[y == 0 ? 0 : y - 1];
          final Float32List nextRow = oldRows[y + 1 >= visIn ? visIn - 1 : y + 1];
          final Float32List first = newRows[2 * y];
          final Float32List second = newRows[2 * y + 1];
          for (var x = 0; x < oldRow.length; x++) {
            final double b75 = 0.75 * oldRow[x];
            first[x] = b75 + 0.25 * prevRow[x];
            second[x] = b75 + 0.25 * nextRow[x];
          }
        }
        buffer[c] = newBuffer;
      }
    }
  }

  /// Decodes lf groups.
  ///
  void _decodeLfGroups() {
    if (captureJpeg && jpegSink == null) {
      _allocJpegSink();
    }
    final ModularStream globalModular = lfGlobal.globalModular;
    final replacementChannels = <ModularChannel>[];
    final replacementIndices = <int>[];
    for (var i = 0; i < globalModular.encodedChannelCount; i++) {
      final ModularChannel chan = globalModular.getChannel(i);
      if (!chan.decoded && chan.vshift >= 3 && chan.hshift >= 3) {
        replacementIndices.add(i);
        replacementChannels.add(ModularChannel.copy(other: chan));
      }
    }

    lfGroups = List<LfGroup?>.filled(numLfGroups, null);
    for (var lfGroupID = 0; lfGroupID < numLfGroups; lfGroupID++) {
      final BitReader reader = toc.sectionReader(1 + lfGroupID);
      final List<ModularChannel> replaced = [for (final c in replacementChannels) ModularChannel.copy(other: c)];
      for (final info in replaced) {
        final int lfGroupHeight = header.lfGroupDim >> info.vshift;
        final int lfGroupWidth = header.lfGroupDim >> info.hshift;
        final int rowStride = ceilDiv(info.width, lfGroupWidth);
        info.originY = lfGroupID ~/ rowStride * lfGroupHeight;
        info.originX = lfGroupID % rowStride * lfGroupWidth;
        info.height = (info.height - info.originY).clamp(0, lfGroupHeight);
        info.width = (info.width - info.originX).clamp(0, lfGroupWidth);
      }
      lfGroups[lfGroupID] = LfGroup(reader: reader, frame: this, lfGroupID: lfGroupID, replaced: replaced);
    }

    for (var lfGroupID = 0; lfGroupID < numLfGroups; lfGroupID++) {
      for (var j = 0; j < replacementIndices.length; j++) {
        final ModularChannel channel = globalModular.getChannel(replacementIndices[j]);
        channel.allocate();
        final ModularChannel newChannel = lfGroups[lfGroupID]!.modularLfGroup.getChannel(j);
        _copyChannelRegion(newChannel, channel);
      }
    }
  }

  /// Decodes pass groups.
  ///
  void _decodePassGroups() {
    final int numPasses = passes.length;
    final isVarDCT = header.encoding == FrameFlags.vardct;
    final passGroups = List<List<ModularStream>>.generate(numPasses, (_) => []);
    final hfGroups = List<List<HfCoefficients?>>.generate(numPasses, (_) => List<HfCoefficients?>.filled(numGroups, null));

    for (var pass = 0; pass < numPasses; pass++) {
      for (var group = 0; group < numGroups; group++) {
        final BitReader reader = toc.sectionReader(2 + numLfGroups + pass * numGroups + group);
        if (isVarDCT) {
          hfGroups[pass][group] = HfCoefficients(reader: reader, frame: this, pass: pass, groupID: group);
        }
        final List<ModularChannel> replaced = [
          for (final c in passes[pass].replacedChannels)
            if (c != null) ModularChannel.copy(other: c),
        ];
        for (final info in replaced) {
          final int groupHeight = header.groupDim >> info.vshift;
          final int groupWidth = header.groupDim >> info.hshift;
          final int rowStride = ceilDiv(info.width, groupWidth);
          info.originY = group ~/ rowStride * groupHeight;
          info.originX = group % rowStride * groupWidth;
          info.height = (info.height - info.originY).clamp(0, groupHeight);
          info.width = (info.width - info.originX).clamp(0, groupWidth);
        }
        if (!isVarDCT && modularLowRes) {
          // Low-res Squeeze decode: skip this large residual group entirely;
          // its target channels are zero-allocated below so the inverse
          // Squeeze upsamples the low-frequency pyramid without it.
          continue;
        }
        final stream = ModularStream.read(reader: reader, ctx: modularContext, streamIndex: 18 + 3 * numLfGroups + numGroups * pass + group, channelArray: replaced);
        stream.decodeChannels(reader);
        passGroups[pass].add(stream);
      }
    }

    final bool skipPg = !isVarDCT && modularLowRes;
    for (var pass = 0; pass < numPasses; pass++) {
      var j = 0;
      for (var i = 0; i < passes[pass].replacedChannels.length; i++) {
        if (passes[pass].replacedChannels[i] == null) {
          continue;
        }
        final ModularChannel channel = lfGlobal.globalModular.getChannel(i);
        channel.allocate();
        if (!skipPg) {
          for (var group = 0; group < numGroups; group++) {
            final ModularChannel newChannel = passGroups[pass][group].getChannel(j);
            _copyChannelRegion(newChannel, channel);
          }
        }
        j++;
      }
    }

    const timings = bool.fromEnvironment('jxl.timings');
    final Stopwatch? sw2 = timings ? (Stopwatch()..start()) : null;
    if (isVarDCT) {
      final List<Float32List> fb0 = buffer[0].floatRows;
      final List<Float32List> fb1 = buffer[1].floatRows;
      final List<Float32List> fb2 = buffer[2].floatRows;
      final bool simdOk = fb0[0].length & 3 == 0 && fb1[0].length & 3 == 0 && fb2[0].length & 3 == 0;
      final List<Float32x4List>? fbV0 = simdOk ? rowVectorViews(fb0) : null;
      final List<Float32x4List>? fbV1 = simdOk ? rowVectorViews(fb1) : null;
      final List<Float32x4List>? fbV2 = simdOk ? rowVectorViews(fb2) : null;
      final List<Float32List> s0 = floatMatrix(256, 256);
      final List<Float32List> s1 = floatMatrix(256, 256);
      final List<Float32List> s2 = floatMatrix(256, 256);
      final List<Float32List> s3 = floatMatrix(256, 256);
      final List<Float32List> s4 = floatMatrix(256, 256);
      for (var pass = 0; pass < numPasses; pass++) {
        for (var group = 0; group < numGroups; group++) {
          invertVarDCTGroup(hfGroups[pass][group]!, pass > 0 ? hfGroups[pass - 1][group] : null, fb0, fb1, fb2, s0, s1, s2, s3, s4, fbV0, fbV1, fbV2);
        }
      }
      if (sw2 != null) {
        // ignore: avoid_print
        print('  vardct inversion: ${sw2.elapsedMilliseconds} ms');
      }
    }
  }

  /// Copies channel region.
  ///
  static void _copyChannelRegion(ModularChannel src, ModularChannel dest) {
    final Int32List sb = src.buffer!;
    final Int32List db = dest.buffer!;
    for (var y = 0; y < src.height; y++) {
      final int destStart = (y + src.originY) * dest.width + src.originX;
      db.setRange(destStart, destStart + src.width, sb, y * src.width);
    }
  }

  /// Processes is visible information in a JPEG XL codestream.
  ///
  bool get isVisible => (header.type == FrameFlags.regularFrame || header.type == FrameFlags.skipProgressive) && (header.duration != 0 || header.isLast);
}
