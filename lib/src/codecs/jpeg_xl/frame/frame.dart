import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/image_buffer.dart';
import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_table_of_contents.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/low_frequency_global.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/low_frequency_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/progressive_passes.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_reconstruction/jpeg_coefficient_sink.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/meta_adaptive_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/render/filters.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_coefficients.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_global.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/high_frequency_pass.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/var_dct_inverter.dart';

/// XYB channel remap: X, Y, B are stored as Y, X, (B - Y) in modular and
/// decode order Y, X, B in VarDCT.
const colorChannelOrder = [1, 0, 2];

/// Per-pass metadata: which not-yet-decoded global modular channels this
/// pass carries, plus the VarDCT HFPass data.
final class Pass {
  /// Exclusive upper coefficient shift decoded by this pass.
  final int maxShift;

  /// Inclusive lower coefficient shift decoded by this pass.
  late final int minShift;

  /// Copies of modular channels whose detail is replaced by this pass.
  late final List<ModularChannel?> replacedChannels;

  /// VarDCT coefficient-order metadata, or `null` for modular frames.
  HighFrequencyPass? highFrequencyPass;

  /// Reads the metadata needed to decode one progressive pass.
  Pass({
    required BitReader reader,
    required Frame frame,
    required int passIndex,
    required int prevMinShift,
  }) : maxShift = passIndex > 0 ? prevMinShift : 3 {
    final ProgressivePasses passes = frame.header.passes;
    var n = -1;
    for (var i = 0; i < passes.lastPassByDownsampling.length; i++) {
      if (passes.lastPassByDownsampling[i] == passIndex) {
        n = i;
        break;
      }
    }
    minShift = n >= 0 ? ceilLog1p(passes.downsamplingFactors[n] - 1) : maxShift;
    final ModularStream stream = frame.lowFrequencyGlobal.globalModularStream;
    replacedChannels = List<ModularChannel?>.filled(stream.encodedChannelCount, null);
    for (var i = 0; i < replacedChannels.length; i++) {
      final ModularChannel chan = stream.getChannel(i);
      if (!chan.decoded) {
        final int m = chan.verticalShift < chan.horizontalShift ? chan.verticalShift : chan.horizontalShift;
        if (minShift <= m && m < maxShift) {
          replacedChannels[i] = ModularChannel.copy(other: chan);
        }
      }
    }
    highFrequencyPass = frame.header.encoding == FrameFlags.vardct ? HighFrequencyPass(reader: reader, frame: frame, passIndex: passIndex) : null;
  }
}

/// One frame of the codestream: header, TOC, and the decode orchestration
/// across LF groups, passes and pass groups (modular and VarDCT).
final class Frame {
  /// Number of full-resolution coding groups in the frame.
  int groupCount = 0;

  /// Bit reader supplying the frame input.
  final BitReader globalReader;

  /// Image-wide header shared by every frame in the codestream.
  final ImageHeader globalMetadata;

  /// Frame header read from [globalReader].
  late FrameHeader header;

  /// Byte ranges for the frame's independently coded sections.
  late FrameTableOfContents tableOfContents;

  /// Frame-wide low-frequency and modular metadata.
  late LowFrequencyGlobal lowFrequencyGlobal;

  /// Shared meta-adaptive tree used by modular streams, when present.
  MetaAdaptiveTree? globalTree;

  /// Frame-wide VarDCT quantization metadata, when present.
  HighFrequencyGlobal? highFrequencyGlobal;

  /// Progressive passes in codestream order.
  List<Pass> passes = [];

  /// Lazily decoded low-frequency groups indexed by group identifier.
  List<LowFrequencyGroup?> lowFrequencyGroups = [];

  /// Horizontal origin of the mutable frame bounds.
  int boundsX0 = 0;

  /// Vertical origin of the mutable frame bounds.
  int boundsY0 = 0;

  /// Width of the mutable frame bounds.
  int boundsWidth = 0;

  /// Height of the mutable frame bounds.
  int boundsHeight = 0;

  /// Number of low-frequency groups covering the frame.
  int lowFrequencyGroupCount = 0;

  /// Number of full-resolution groups in one frame row.
  int groupRowStride = 0;

  /// Number of low-frequency groups in one frame row.
  int lowFrequencyGroupRowStride = 0;

  /// Per-channel frame output, sized to the padded frame size.
    late List<ImageBuffer> buffer;

  /// When set (JPEG reconstruction), the decode captures quantized DC/AC
  /// coefficients into [jpegCoefficientSink] via gated hooks in Lf/HighFrequencyCoefficients.
    bool captureJpegReconstruction = false;

  /// Optional destination for quantized coefficients used by JPEG reconstruction.
    JpegCoefficientSink? jpegCoefficientSink;

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
    List<ImageBuffer>? lowFrequencyFrame;

  /// Creates a frame reader attached to image-wide metadata.
    Frame({
    required this.globalReader,
    required this.globalMetadata,
  });

  /// Number of TOC entries for this frame's structure.
    int get tableOfContentsEntryCount {
    if (groupCount == 1 && header.passes.passCount == 1) {
      return 1;
    }
    // lowFrequencyGlobal + one per LF group + highFrequencyGlobal + one per pass per group.
    return 1 + lowFrequencyGroupCount + 1 + groupCount * header.passes.passCount;
  }

  /// Number of color channels in the frame representation (not the output).
    int get colorChannelCount => globalMetadata.xybEncoded || header.encoding == FrameFlags.vardct ? 3 : globalMetadata.colorChannelCount;

  /// Returns the padded dimensions used for frame decoding.
    ({int width, int height}) get paddedFrameSize {
    var factorY = 0;
    var factorX = 0;
    for (var i = 0; i < 3; i++) {
      if (header.jpegVerticalUpsamplingShift[i] > factorY) {
        factorY = header.jpegVerticalUpsamplingShift[i];
      }
      if (header.jpegHorizontalUpsamplingShift[i] > factorX) {
        factorX = header.jpegHorizontalUpsamplingShift[i];
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

  /// Allocates [jpegCoefficientSink], one entry per color channel (capture is keyed by
  /// JPEG component: DC channel `j` and AC channel `colorChannelOrder[j]`). Component `j`'s
  /// block grid follows the subsampling of its governing JXL channel.
    void _allocateJpegCoefficientSink() {
    final ({int height, int width}) padded = paddedFrameSize;
    final int lumaWidthInBlocks = padded.width >> 3;
    final int lumaHeightInBlocks = padded.height >> 3;
    final List<int> channelWidthsInBlocks = [];
    final List<int> channelHeightsInBlocks = [];
    for (int componentIndex = 0; componentIndex < 3; componentIndex++) {
      channelWidthsInBlocks.add(lumaWidthInBlocks >> header.jpegHorizontalUpsamplingShift[colorChannelOrder[componentIndex]]);
      channelHeightsInBlocks.add(lumaHeightInBlocks >> header.jpegVerticalUpsamplingShift[colorChannelOrder[componentIndex]]);
    }
    jpegCoefficientSink = JpegCoefficientSink(widthInBlocks: channelWidthsInBlocks, heightInBlocks: channelHeightsInBlocks);
  }

  /// Builds the modular metadata inherited by each frame substream.
    ModularFrameContext get modularContext => ModularFrameContext(
    frameWidth: boundsWidth,
    frameHeight: boundsHeight,
    groupDimension: header.groupDimension,
    globalTree: globalTree,
    extraChannelDimensionShifts: [for (final ec in globalMetadata.extraChannels) ec.dimensionShift],
    bitDepth: globalMetadata.bitDepth.bitsPerSample,
  );

  /// Copies decoded global modular channels into the frame output buffers.
    void _copyOutModular() {
    final List<ModularChannel> channels = lowFrequencyGlobal.globalModularStream.channels;
    final int colors = colorChannelCount;
    for (var c = 0; c < channels.length; c++) {
      final bool isModularColor = header.encoding == FrameFlags.modular && c < colors;
      final bool isModularXYB = globalMetadata.xybEncoded && isModularColor;
      // X, Y, B is encoded as Y, X, (B - Y).
      final int cOut = (isModularXYB ? colorChannelOrder[c] : c) + buffer.length - channels.length;
      final Int32List src = channels[c].buffer!;
      final int srcWidth = channels[c].width;
      if (isModularXYB && c == 2) {
        final List<Float32List> out = buffer[cOut].floatRows;
        final double scaleFactor = lowFrequencyGlobal.lowFrequencyDequantization[cOut];
        final Int32List srcY = channels[0].buffer!;
        for (var y = 0; y < boundsHeight; y++) {
          final Float32List row = out[y];
          for (var x = 0; x < boundsWidth; x++) {
            row[x] = scaleFactor * (srcY[y * srcWidth + x] + src[y * srcWidth + x]);
          }
        }
      } else if (buffer[cOut].isFloat) {
        final List<Float32List> out = buffer[cOut].floatRows;
        final double scaleFactor = isModularXYB ? lowFrequencyGlobal.lowFrequencyDequantization[cOut] : 1.0;
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

  /// Returns the two-dimensional location of a coding group.
    ({int y, int x}) getGroupLocation(int groupId) => (y: groupId ~/ groupRowStride, x: groupId % groupRowStride);

  /// Returns the two-dimensional location of a low-frequency group.
    ({int y, int x}) lowFrequencyGroupLocation(int lowFrequencyGroupId) => (y: lowFrequencyGroupId ~/ lowFrequencyGroupRowStride, x: lowFrequencyGroupId % lowFrequencyGroupRowStride);

  /// Position of this group within its LF group, in group units.
    ({int y, int x}) groupPositionInLowFrequencyGroup(int lowFrequencyGroupId, int groupId) {
    final ({int x, int y}) gr = getGroupLocation(groupId);
    final ({int x, int y}) lf = lowFrequencyGroupLocation(lowFrequencyGroupId);
    return (y: gr.y - (lf.y << 3), x: gr.x - (lf.x << 3));
  }

  /// Returns the low-frequency group containing [groupId].
    LowFrequencyGroup lowFrequencyGroupFor(int groupId) {
    final ({int x, int y}) pos = getGroupLocation(groupId);
    return lowFrequencyGroups[(pos.y >> 3) * lowFrequencyGroupRowStride + (pos.x >> 3)]!;
  }

  /// Returns the clipped pixel dimensions of [groupId].
    ({int height, int width}) groupSize(int groupId) {
    final ({int x, int y}) pos = getGroupLocation(groupId);
    final ({int height, int width}) padded = paddedFrameSize;
    final int height = header.groupDimension < padded.height - pos.y * header.groupDimension ? header.groupDimension : padded.height - pos.y * header.groupDimension;
    final int width = header.groupDimension < padded.width - pos.x * header.groupDimension ? header.groupDimension : padded.width - pos.x * header.groupDimension;
    return (height: height, width: width);
  }

  /// Returns the clipped pixel dimensions of [lowFrequencyGroupId].
    ({int height, int width}) lowFrequencyGroupSize(int lowFrequencyGroupId) {
    final ({int x, int y}) pos = lowFrequencyGroupLocation(lowFrequencyGroupId);
    final ({int height, int width}) padded = paddedFrameSize;
    final int height = header.lowFrequencyGroupDimension < padded.height - pos.y * header.lowFrequencyGroupDimension
        ? header.lowFrequencyGroupDimension
        : padded.height - pos.y * header.lowFrequencyGroupDimension;
    final int width = header.lowFrequencyGroupDimension < padded.width - pos.x * header.lowFrequencyGroupDimension
        ? header.lowFrequencyGroupDimension
        : padded.width - pos.x * header.lowFrequencyGroupDimension;
    return (height: height, width: width);
  }

  /// Reads the frame table of contents.
    void readTableOfContents({bool allowTruncated = false}) {
    if (tableOfContentsEntryCount > 1 << 20) {
      throw const JpegXlInvalidBitstreamException(message: 'too many TOC sections');
    }
    tableOfContents = FrameTableOfContents.read(
      reader: globalReader,
      sectionCount: tableOfContentsEntryCount,
      allowTruncated: allowTruncated,
    );
  }

  /// Streaming preview: decodes only LowFrequencyGlobal and the LF groups (the DC
  /// image for VarDCT frames). Requires those TOC sections to be present.
    void decodeLfOnly() {
    lowFrequencyGlobal = LowFrequencyGlobal.read(reader: tableOfContents.sectionReader(0), frame: this);
    _decodeLfGroups();
  }

  /// Reads and validates the frame header.
    FrameHeader readFrameHeader() {
    globalReader.zeroPadToByte();
    header = FrameHeader.read(reader: globalReader, parent: globalMetadata);
    boundsX0 = header.x0;
    boundsY0 = header.y0;
    boundsWidth = header.width;
    boundsHeight = header.height;
    groupRowStride = ceilDiv(boundsWidth, header.groupDimension);
    lowFrequencyGroupRowStride = ceilDiv(boundsWidth, header.groupDimension << 3);
    groupCount = groupRowStride * ceilDiv(boundsHeight, header.groupDimension);
    lowFrequencyGroupCount = lowFrequencyGroupRowStride * ceilDiv(boundsHeight, header.groupDimension << 3);
    return header;
  }

  /// Decodes this frame.
    void decodeFrame({List<ImageBuffer>? lowFrequencyFrame, bool modularLowRes = false}) {
    this.lowFrequencyFrame = lowFrequencyFrame;
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

    final isVarDct = header.encoding == FrameFlags.vardct;
    lowFrequencyGlobal = LowFrequencyGlobal.read(reader: tableOfContents.sectionReader(0), frame: this);
    mark('lowFrequencyGlobal');
    // Low-res Squeeze decode is only valid for a responsive frame (its
    // pass-group channels are high-frequency residuals). For a non-Squeeze
    // modular frame, bail right after the cheap LowFrequencyGlobal read — before any
    // LF-group/assembly work — so the caller (`_modularLowResImageFor`) sees
    // `!usesSqueeze` and falls back to a full decode with minimal waste.
    if (modularLowRes && !isVarDct && !lowFrequencyGlobal.globalModularStream.usesSqueeze) {
      return;
    }
    final ({int height, int width}) padded = paddedFrameSize;
    final int colors = colorChannelCount;
    final int channelCount = colors + globalMetadata.extraChannels.length;
    buffer = [
      for (var c = 0; c < channelCount; c++)
        if (c < colors && (globalMetadata.xybEncoded || isVarDct))
          ImageBuffer.float32(
            height: c < 3 ? padded.height >> header.jpegVerticalUpsamplingShift[c] : padded.height,
            width: c < 3 ? padded.width >> header.jpegHorizontalUpsamplingShift[c] : padded.width,
          )
        else
          ImageBuffer.int32(height: padded.height, width: padded.width),
    ];

    _decodeLfGroups();
    mark('lowFrequencyGroups');

    final BitReader hfGlobalReader = tableOfContents.sectionReader(1 + lowFrequencyGroupCount);
    if (isVarDct) {
      highFrequencyGlobal = HighFrequencyGlobal(reader: hfGlobalReader, frame: this);
    }
    passes = [];
    for (var i = 0; i < header.passes.passCount; i++) {
      passes.add(Pass(reader: hfGlobalReader, frame: this, passIndex: i, prevMinShift: i > 0 ? passes[i - 1].minShift : 0));
    }

    mark('highFrequencyGlobal+passes');
    _decodePassGroups();
    mark('passGroups');

    lowFrequencyGlobal.globalModularStream.applyTransforms();
    _copyOutModular();
    mark('transforms+copyOut');

    _invertSubsampling();
    if (header.restorationFilter.usesGaborish) {
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
    /// Neighbor taps mirror at the *visible* subsampled extent, matching
  /// libjxl's render pipeline: the padded DCT rows/columns beyond
  /// ceil(visible / 2) are never read. (jxlatte reads the padded samples
  /// instead, which shifts the final visible row on 4:2:0 images whose
  /// height is not a block multiple.)
  void _invertSubsampling() {
    for (var c = 0; c < 3; c++) {
      int xShift = header.jpegHorizontalUpsamplingShift[c];
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
      int yShift = header.jpegVerticalUpsamplingShift[c];
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
    void _decodeLfGroups() {
    if (captureJpegReconstruction && jpegCoefficientSink == null) {
      _allocateJpegCoefficientSink();
    }
    final ModularStream globalModularStream = lowFrequencyGlobal.globalModularStream;
    final replacementChannels = <ModularChannel>[];
    final replacementIndices = <int>[];
    for (var i = 0; i < globalModularStream.encodedChannelCount; i++) {
      final ModularChannel chan = globalModularStream.getChannel(i);
      if (!chan.decoded && chan.verticalShift >= 3 && chan.horizontalShift >= 3) {
        replacementIndices.add(i);
        replacementChannels.add(ModularChannel.copy(other: chan));
      }
    }

    lowFrequencyGroups = List<LowFrequencyGroup?>.filled(lowFrequencyGroupCount, null);
    for (var lowFrequencyGroupId = 0; lowFrequencyGroupId < lowFrequencyGroupCount; lowFrequencyGroupId++) {
      final BitReader reader = tableOfContents.sectionReader(1 + lowFrequencyGroupId);
      final List<ModularChannel> replaced = [for (final c in replacementChannels) ModularChannel.copy(other: c)];
      for (final info in replaced) {
        final int lowFrequencyGroupHeight = header.lowFrequencyGroupDimension >> info.verticalShift;
        final int lowFrequencyGroupWidth = header.lowFrequencyGroupDimension >> info.horizontalShift;
        final int rowStride = ceilDiv(info.width, lowFrequencyGroupWidth);
        info.verticalOrigin = lowFrequencyGroupId ~/ rowStride * lowFrequencyGroupHeight;
        info.horizontalOrigin = lowFrequencyGroupId % rowStride * lowFrequencyGroupWidth;
        info.height = (info.height - info.verticalOrigin).clamp(0, lowFrequencyGroupHeight);
        info.width = (info.width - info.horizontalOrigin).clamp(0, lowFrequencyGroupWidth);
      }
      lowFrequencyGroups[lowFrequencyGroupId] = LowFrequencyGroup(reader: reader, frame: this, lowFrequencyGroupId: lowFrequencyGroupId, replaced: replaced);
    }

    for (var lowFrequencyGroupId = 0; lowFrequencyGroupId < lowFrequencyGroupCount; lowFrequencyGroupId++) {
      for (var j = 0; j < replacementIndices.length; j++) {
        final ModularChannel channel = globalModularStream.getChannel(replacementIndices[j]);
        channel.allocate();
        final ModularChannel newChannel = lowFrequencyGroups[lowFrequencyGroupId]!.modularStream.getChannel(j);
        _copyChannelRegion(newChannel, channel);
      }
    }
  }

  /// Decodes pass groups.
    void _decodePassGroups() {
    final int passCount = passes.length;
    final isVarDct = header.encoding == FrameFlags.vardct;
    final passGroups = List<List<ModularStream>>.generate(passCount, (_) => []);
    final highFrequencyGroups = List<List<HighFrequencyCoefficients?>>.generate(passCount, (_) => List<HighFrequencyCoefficients?>.filled(groupCount, null));

    for (var pass = 0; pass < passCount; pass++) {
      for (var group = 0; group < groupCount; group++) {
        final BitReader reader = tableOfContents.sectionReader(2 + lowFrequencyGroupCount + pass * groupCount + group);
        if (isVarDct) {
          highFrequencyGroups[pass][group] = HighFrequencyCoefficients(reader: reader, frame: this, pass: pass, groupId: group);
        }
        final List<ModularChannel> replaced = [
          for (final c in passes[pass].replacedChannels)
            if (c != null) ModularChannel.copy(other: c),
        ];
        for (final info in replaced) {
          final int groupHeight = header.groupDimension >> info.verticalShift;
          final int groupWidth = header.groupDimension >> info.horizontalShift;
          final int rowStride = ceilDiv(info.width, groupWidth);
          info.verticalOrigin = group ~/ rowStride * groupHeight;
          info.horizontalOrigin = group % rowStride * groupWidth;
          info.height = (info.height - info.verticalOrigin).clamp(0, groupHeight);
          info.width = (info.width - info.horizontalOrigin).clamp(0, groupWidth);
        }
        if (!isVarDct && modularLowRes) {
          // Low-res Squeeze decode: skip this large residual group entirely;
          // its target channels are zero-allocated below so the inverse
          // Squeeze upsamples the low-frequency pyramid without it.
          continue;
        }
        final stream = ModularStream.read(reader: reader, context: modularContext, streamIndex: 18 + 3 * lowFrequencyGroupCount + groupCount * pass + group, channelArray: replaced);
        stream.decodeChannels(reader);
        passGroups[pass].add(stream);
      }
    }

    final bool skipPg = !isVarDct && modularLowRes;
    for (var pass = 0; pass < passCount; pass++) {
      var j = 0;
      for (var i = 0; i < passes[pass].replacedChannels.length; i++) {
        if (passes[pass].replacedChannels[i] == null) {
          continue;
        }
        final ModularChannel channel = lowFrequencyGlobal.globalModularStream.getChannel(i);
        channel.allocate();
        if (!skipPg) {
          for (var group = 0; group < groupCount; group++) {
            final ModularChannel newChannel = passGroups[pass][group].getChannel(j);
            _copyChannelRegion(newChannel, channel);
          }
        }
        j++;
      }
    }

    const timings = bool.fromEnvironment('jxl.timings');
    final Stopwatch? sw2 = timings ? (Stopwatch()..start()) : null;
    if (isVarDct) {
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
      for (var pass = 0; pass < passCount; pass++) {
        for (var group = 0; group < groupCount; group++) {
          invertVarDctGroup(highFrequencyGroups[pass][group]!, pass > 0 ? highFrequencyGroups[pass - 1][group] : null, fb0, fb1, fb2, s0, s1, s2, s3, s4, fbV0, fbV1, fbV2);
        }
      }
      if (sw2 != null) {
        // ignore: avoid_print
        print('  vardct inversion: ${sw2.elapsedMilliseconds} ms');
      }
    }
  }

  /// Copies channel region.
    static void _copyChannelRegion(ModularChannel src, ModularChannel dest) {
    final Int32List sb = src.buffer!;
    final Int32List db = dest.buffer!;
    for (var y = 0; y < src.height; y++) {
      final int destStart = (y + src.verticalOrigin) * dest.width + src.horizontalOrigin;
      db.setRange(destStart, destStart + src.width, sb, y * src.width);
    }
  }

  /// Whether this frame contributes visible output.
    bool get isVisible => (header.type == FrameFlags.regularFrame || header.type == FrameFlags.skipProgressive) && (header.duration != 0 || header.isLast);
}
