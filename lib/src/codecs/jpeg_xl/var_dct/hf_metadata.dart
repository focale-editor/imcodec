import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/lf_group.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Per-LF-group HF metadata: the varblock map (transform types + positions),
/// per-block quant multipliers, CfL factors and EPF sharpness.
final class HfMetadata {
  /// Stores the nb blocks value used while processing JPEG XL data.
  ///
  late final int nbBlocks;

  /// Stores the block width value used while processing JPEG XL data.
  ///
  late final int blockWidth;

  /// Stores the dct select idx state used internally by the JPEG XL codec.
  ///
  late final Int32List _dctSelectIdx;

  /// Stores the hf multiplier value used while processing JPEG XL data.
  ///
  late final Int32List hfMultiplier;

  /// 4 channels: xFromY, bFromY, blockInfo (2 x nbBlocks), sharpness.
  late final List<ModularChannel> hfStreamChannels;

  /// Stores the block y value used while processing JPEG XL data.
  ///
  late final Int32List blockY;

  /// Stores the block x value used while processing JPEG XL data.
  ///
  late final Int32List blockX;

  /// Stores the group block indices state used internally by the JPEG XL codec.
  ///
  List<Int32List>? _groupBlockIndices;

  /// Creates Hf metadata data for JPEG XL processing.
  ///
  HfMetadata({
    required BitReader reader,
    required LfGroup parent,
    required Frame frame,
  }) {
    final int bh = parent.blockHeight;
    final int bw = parent.blockWidth;
    final int n = ceilLog2(bh * bw);
    nbBlocks = 1 + reader.readBits(n);
    final int correlationHeight = (bh + 7) ~/ 8;
    final int correlationWidth = (bw + 7) ~/ 8;
    final xFromY = ModularChannel(height: correlationHeight, width: correlationWidth, vshift: 0, hshift: 0);
    final bFromY = ModularChannel(height: correlationHeight, width: correlationWidth, vshift: 0, hshift: 0);
    final blockInfo = ModularChannel(height: 2, width: nbBlocks, vshift: 0, hshift: 0);
    final sharpness = ModularChannel(height: bh, width: bw, vshift: 0, hshift: 0);
    final hfStream = ModularStream.read(reader: reader, ctx: frame.modularContext, streamIndex: 1 + 2 * frame.numLfGroups + parent.lfGroupID, channelArray: [xFromY, bFromY, blockInfo, sharpness]);
    hfStream.decodeChannels(reader);
    hfStreamChannels = [for (var i = 0; i < 4; i++) hfStream.getChannel(i)];

    blockWidth = bw;
    _dctSelectIdx = Int32List(bh * bw)..fillRange(0, bh * bw, -1);
    hfMultiplier = Int32List(bh * bw);
    blockY = Int32List(nbBlocks);
    blockX = Int32List(nbBlocks);
    final Int32List blockInfoBuf = hfStreamChannels[2].buffer!;
    var lastY = 0;
    var lastX = 0;
    for (var i = 0; i < nbBlocks; i++) {
      final int type = blockInfoBuf[i]; // row 0: type
      if (type > 26 || type < 0) {
        throw JpegXlInvalidBitstreamException(message: 'invalid transform type: $type');
      }
      final TransformType tt = TransformType.values[type];
      final int mul = 1 + blockInfoBuf[nbBlocks + i]; // row 1: multiplier - 1
      final int pos = _placeBlock(bh, bw, lastY, lastX, tt, mul);
      lastY = pos >> 20;
      lastX = pos & 0xFFFFF;
      blockY[i] = lastY;
      blockX[i] = lastX;
    }
  }

  /// Processes dct select at information in a JPEG XL codestream.
  ///
  TransformType? dctSelectAt(int y, int x) {
    final int idx = _dctSelectIdx[y * blockWidth + x];
    return idx < 0 ? null : TransformType.values[idx];
  }

  /// Processes hf multiplier at information in a JPEG XL codestream.
  ///
  int hfMultiplierAt(int y, int x) => hfMultiplier[y * blockWidth + x];

  /// Processes sharpness at information in a JPEG XL codestream.
  ///
  int sharpnessAt(int y, int x) => hfStreamChannels[3].buffer![y * blockWidth + x];

  /// [nbBlocks] block indices partitioned by the (group-dim-sized) pass-group
  /// they fall into, keyed by `(blockY[i] >> 5) * 8 + (blockX[i] >> 5)` — an
  /// LF group always spans exactly 8x8 groups (`Frame.groupPosInLFGroup`'s
  /// `pos.y`/`pos.x` range), so this fixed 64-bucket layout mirrors the same
  /// group-grid assumption `HfCoefficients` already hardcodes via `<< 5`/
  /// `32`. Computed once per LF group and shared by every pass and every
  /// pass-group that reads it, instead of each one separately re-scanning
  /// all [nbBlocks] entries to find its own subset.
  List<Int32List> blockIndicesByGroup() {
    final List<Int32List>? cached = _groupBlockIndices;
    if (cached != null) {
      return cached;
    }
    final counts = Int32List(64);
    for (var i = 0; i < nbBlocks; i++) {
      counts[(blockY[i] >> 5) * 8 + (blockX[i] >> 5)]++;
    }
    final buckets = List<Int32List>.generate(64, (k) => Int32List(counts[k]));
    final fillPos = Int32List(64);
    for (var i = 0; i < nbBlocks; i++) {
      final int key = (blockY[i] >> 5) * 8 + (blockX[i] >> 5);
      buckets[key][fillPos[key]++] = i;
    }
    return _groupBlockIndices = buckets;
  }

  /// Places [block] at the first free position at/after (lastY, lastX) in
  /// raster order; returns (y << 20) | x.
  int _placeBlock(int bh, int bw, int lastY, int lastX, TransformType block, int mul) {
    var x = lastX;
    for (var y = lastY; y < bh; y++, x = 0) {
      final int rowBase = y * bw;
      outerX:
      for (; x < bw; x++) {
        if (block.dctSelectWidth + x > bw) {
          break; // next row
        }
        // Check the space is free.
        for (var ix = 0; ix < block.dctSelectWidth; ix++) {
          final int idx = _dctSelectIdx[rowBase + x + ix];
          if (idx >= 0) {
            x += TransformType.values[idx].dctSelectWidth - 1;
            continue outerX;
          }
        }
        if (block.dctSelectHeight + y > bh) {
          throw const JpegXlInvalidBitstreamException(message: 'block does not fit vertically');
        }
        for (var iy = 0; iy < block.dctSelectHeight; iy++) {
          final int base = (y + iy) * bw + x;
          _dctSelectIdx.fillRange(base, base + block.dctSelectWidth, block.type);
          hfMultiplier.fillRange(base, base + block.dctSelectWidth, mul);
        }
        return (y << 20) | x;
      }
    }
    throw const JpegXlInvalidBitstreamException(message: 'could not place block');
  }
}
