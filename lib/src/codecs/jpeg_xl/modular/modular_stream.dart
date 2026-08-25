import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/delta_palette.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/ma_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/transform_info.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/wp_params.dart';

/// Stores the permutation lut state used internally by the JPEG XL codec.
///
const _permutationLut = [
  [0, 1, 2], [1, 2, 0], [2, 0, 1], //
  [0, 2, 1], [1, 0, 2], [2, 1, 0],
];

/// What a modular (sub-)stream needs to know about its enclosing frame.
final class ModularFrameContext {
  /// The modular frame size (frame bounds).
  final int frameWidth;

  /// Stores the frame height value used while processing JPEG XL data.
  ///
  final int frameHeight;

  /// Stores the group dim value used while processing JPEG XL data.
  ///
  final int groupDim;

  /// Stores the global tree value used while processing JPEG XL data.
  ///
  final MaTree? globalTree;

  /// dimShift per extra channel.
  final List<int> ecDimShifts;

  /// Image bits per sample (used by the palette transform).
  final int bitDepth;

  /// Creates Modular frame context data for JPEG XL processing.
  ///
  const ModularFrameContext({required this.frameWidth, required this.frameHeight, required this.groupDim, required this.globalTree, required this.ecDimShifts, required this.bitDepth});
}

/// A modular bitstream section: channel list, transform chain, MA tree and
/// entropy stream, with forward parsing and inverse transform application.
final class ModularStream {
  /// Stores the ctx value used while processing JPEG XL data.
  ///
  final ModularFrameContext ctx;

  /// Stores the stream index value used while processing JPEG XL data.
  ///
  final int streamIndex;

  /// Stores the nb meta channels value used while processing JPEG XL data.
  ///
  int nbMetaChannels = 0;

  /// Stores the dist multiplier value used while processing JPEG XL data.
  ///
  int distMultiplier = 1;

  /// Stores the tree value used while processing JPEG XL data.
  ///
  MaTree? tree;

  /// Stores the wp params value used while processing JPEG XL data.
  ///
  WpParams? wpParams;

  /// Stores the transforms value used while processing JPEG XL data.
  ///
  List<TransformInfo> transforms = const [];

  /// Stores the stream value used while processing JPEG XL data.
  ///
  EntropyStream? stream;

  /// Transforms ed.
  ///
  bool _transformed = false;

  /// Stores the channels value used while processing JPEG XL data.
  ///
  final List<ModularChannel> channels = [];

  /// Stores the squeeze map state used internally by the JPEG XL codec.
  ///
  final Map<int, List<SqueezeParam>> _squeezeMap = {};

  /// Reads the stream header. If [channelArray] is given, those channels are
  /// used directly (group streams); otherwise [channelCount] full-frame
  /// channels are created, of which the last `channelCount - ecStart` are
  /// extra channels.
  ModularStream.read({
    required BitReader reader,
    required this.ctx,
    required this.streamIndex,
    List<ModularChannel>? channelArray,
    int channelCount = 0,
    int ecStart = 0,
  }) {
    final int effectiveChannelCount = channelArray?.length ?? channelCount;
    if (effectiveChannelCount == 0) {
      distMultiplier = 1;
      return;
    }
    final bool useGlobalTree = reader.readBool();
    wpParams = WpParams.read(reader: reader);
    final int nbTransforms = reader.readU32(0, 0, 1, 0, 2, 4, 18, 8);
    transforms = List.generate(nbTransforms, (_) => TransformInfo.read(reader: reader));

    if (channelArray == null) {
      for (var i = 0; i < channelCount; i++) {
        final int dimShift = i < ecStart ? 0 : ctx.ecDimShifts[i - ecStart];
        channels.add(ModularChannel(height: ctx.frameHeight, width: ctx.frameWidth, vshift: dimShift, hshift: dimShift));
      }
    } else {
      channels.addAll(channelArray);
    }

    for (var i = 0; i < nbTransforms; i++) {
      final TransformInfo t = transforms[i];
      if (t.tr == TransformInfo.palette || t.tr == TransformInfo.rct) {
        final int needed = t.tr == TransformInfo.rct ? 3 : t.numC;
        if (t.beginC < 0 || needed < 1 || t.beginC + needed > channels.length) {
          throw const JpegXlInvalidBitstreamException(message: 'transform channel range out of bounds');
        }
      }
      if (t.tr == TransformInfo.palette) {
        if (t.beginC < nbMetaChannels) {
          nbMetaChannels += 2 - t.numC;
        } else {
          nbMetaChannels++;
        }
        final int start = t.beginC + 1;
        for (var j = start; j < t.beginC + t.numC; j++) {
          channels.removeAt(start);
        }
        if (t.nbDeltas > 0 && t.dPred == 6) {
          channels[t.beginC].forceWp = true;
        }
        channels.insert(0, ModularChannel(height: t.numC, width: t.nbColors, vshift: -1, hshift: -1));
      } else if (t.tr == TransformInfo.squeeze) {
        final squeezeList = <SqueezeParam>[];
        if (t.sp!.isEmpty) {
          final int first = nbMetaChannels;
          final int count = channels.length - first;
          // Default squeeze parameters operate on the first non-meta
          // channel's size (libjxl uses channel[nb_meta_channels]).
          int w = channels[first].width;
          int h = channels[first].height;
          if (count > 2 && channels[first + 1].sizeEquals(channels[first])) {
            squeezeList.add(SqueezeParam(horizontal: true, inPlace: false, beginC: first + 1, numC: 2));
            squeezeList.add(SqueezeParam(horizontal: false, inPlace: false, beginC: first + 1, numC: 2));
          }
          if (h >= w && h > 8) {
            squeezeList.add(SqueezeParam(horizontal: false, inPlace: true, beginC: first, numC: count));
            h = (h + 1) ~/ 2;
          }
          while (w > 8 || h > 8) {
            if (w > 8) {
              squeezeList.add(SqueezeParam(horizontal: true, inPlace: true, beginC: first, numC: count));
              w = (w + 1) ~/ 2;
            }
            if (h > 8) {
              squeezeList.add(SqueezeParam(horizontal: false, inPlace: true, beginC: first, numC: count));
              h = (h + 1) ~/ 2;
            }
          }
        } else {
          squeezeList.addAll(t.sp!);
        }
        _squeezeMap[i] = squeezeList;
        for (final sp in squeezeList) {
          final int begin = sp.beginC;
          final int end = begin + sp.numC - 1;
          if (begin < 0 || sp.numC < 1 || end >= channels.length) {
            throw const JpegXlInvalidBitstreamException(message: 'squeeze channel range out of bounds');
          }
          final int offset = sp.inPlace ? end + 1 : channels.length;
          if (begin < nbMetaChannels) {
            if (!sp.inPlace) {
              throw const JpegXlInvalidBitstreamException(message: 'squeeze meta must be in place');
            }
            if (end >= nbMetaChannels) {
              throw const JpegXlInvalidBitstreamException(message: 'squeeze meta must end in meta');
            }
            nbMetaChannels += sp.numC;
          }
          for (var k = begin; k <= end; k++) {
            final ModularChannel chan = channels[k];
            final int r = offset + k - begin;
            final ModularChannel residu;
            if (sp.horizontal) {
              final int w = chan.width;
              chan.width = (w + 1) ~/ 2;
              chan.hshift++;
              residu = ModularChannel.copy(other: chan);
              residu.width = w ~/ 2;
            } else {
              final int h = chan.height;
              chan.height = (h + 1) ~/ 2;
              chan.vshift++;
              residu = ModularChannel.copy(other: chan);
              residu.height = h ~/ 2;
            }
            channels.insert(r, residu);
          }
        }
      } else if (t.tr == TransformInfo.rct) {
        // RCT doesn't modify the channel list.
        continue;
      } else {
        throw JpegXlInvalidBitstreamException(message: 'illegal transform ${t.tr}');
      }
    }

    if (!useGlobalTree) {
      tree = MaTree.read(reader: reader);
    } else {
      tree = ctx.globalTree;
      if (tree == null) {
        throw const JpegXlInvalidBitstreamException(message: 'stream uses global tree but no global tree exists');
      }
    }
    stream = EntropyStream.clone(other: tree!.stream!);

    distMultiplier = 0;
    for (final ModularChannel c in channels) {
      if (c.width > distMultiplier) {
        distMultiplier = c.width;
      }
    }
  }

  /// Stores the encoded channel count value used while processing JPEG XL data.
  ///
  int get encodedChannelCount => channels.length;

  /// Whether this stream applies a Squeeze (responsive) transform — the
  /// precondition for the decoder's low-res Squeeze downscale path.
  bool get usesSqueeze => transforms.any((t) => t.tr == TransformInfo.squeeze);

  /// Processes get channel information in a JPEG XL codestream.
  ///
  ModularChannel getChannel(int index) => channels[index];

  /// Processes decode channels information in a JPEG XL codestream.
  ///
  void decodeChannels(BitReader reader, {bool partial = false}) {
    var channelIndex = 0;
    for (var i = 0; i < channels.length; i++) {
      final ModularChannel channel = channels[i];
      if (partial && i >= nbMetaChannels && (channel.height > ctx.groupDim || channel.width > ctx.groupDim)) {
        break;
      }
      if (channel.width == 0 || channel.height == 0) {
        channel.allocate();
      } else {
        channel.decode(reader, stream!, wpParams, tree!, channels, channelIndex, streamIndex, distMultiplier);
        channelIndex++;
      }
    }
    if (stream != null && !stream!.validateFinalState()) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal final modular state');
    }
    if (!partial) {
      applyTransforms();
    }
  }

  /// Processes apply transforms information in a JPEG XL codestream.
  ///
  void applyTransforms() {
    if (_transformed) {
      return;
    }
    _transformed = true;
    for (int i = transforms.length - 1; i >= 0; i--) {
      final TransformInfo t = transforms[i];
      if (t.tr == TransformInfo.squeeze) {
        final List<SqueezeParam> spa = _squeezeMap[i]!;
        for (int j = spa.length - 1; j >= 0; j--) {
          final SqueezeParam sp = spa[j];
          final int begin = sp.beginC;
          final int end = begin + sp.numC - 1;
          final int offset = sp.inPlace ? end + 1 : channels.length + begin - end - 1;
          for (var c = begin; c <= end; c++) {
            final int r = offset + c - begin;
            final ModularChannel chan = channels[c];
            final ModularChannel residu = channels[r];
            final ModularChannel output;
            if (sp.horizontal) {
              output = ModularChannel.inverseHorizontalSqueeze(ModularChannel(height: chan.height, width: chan.width + residu.width, vshift: chan.vshift, hshift: chan.hshift - 1), chan, residu);
            } else {
              output = ModularChannel.inverseVerticalSqueeze(ModularChannel(height: chan.height + residu.height, width: chan.width, vshift: chan.vshift - 1, hshift: chan.hshift), chan, residu);
            }
            channels[c] = output;
          }
          for (var c = 0; c < end - begin + 1; c++) {
            channels.removeAt(offset);
          }
        }
      } else if (t.tr == TransformInfo.rct) {
        final int permutation = t.rctType ~/ 7;
        final int type = t.rctType % 7;
        if (permutation >= _permutationLut.length) {
          throw const JpegXlInvalidBitstreamException(message: 'invalid RCT permutation');
        }
        final int start = t.beginC;
        final List<ModularChannel> v = [channels[start], channels[start + 1], channels[start + 2]];
        if (!v[1].sizeEquals(v[0]) || !v[2].sizeEquals(v[1])) {
          throw const JpegXlInvalidBitstreamException(message: 'RCT needs three equal-size channels');
        }
        final int n = v[0].height * v[0].width;
        final Int32List b0 = v[0].buffer!;
        final Int32List b1 = v[1].buffer!;
        final Int32List b2 = v[2].buffer!;
        switch (type) {
          case 0:
            break;
          case 1:
            for (var p = 0; p < n; p++) {
              b2[p] += b0[p];
            }
          case 2:
            for (var p = 0; p < n; p++) {
              b1[p] += b0[p];
            }
          case 3:
            for (var p = 0; p < n; p++) {
              final int a = b0[p];
              b2[p] += a;
              b1[p] += a;
            }
          case 4:
            for (var p = 0; p < n; p++) {
              b1[p] += (b0[p] + b2[p]) >> 1;
            }
          case 5:
            for (var p = 0; p < n; p++) {
              final int a = b0[p];
              final int ac = a + b2[p];
              b1[p] += (a + ac) >> 1;
              b2[p] = ac;
            }
          case 6:
            for (var p = 0; p < n; p++) {
              final int b = b1[p];
              final int c = b2[p];
              final int tmp = b0[p] - (c >> 1);
              final int f = tmp - (b >> 1);
              b0[p] = f + b;
              b1[p] = c + tmp;
              b2[p] = f;
            }
        }
        for (var j = 0; j < 3; j++) {
          channels[start + _permutationLut[permutation][j]] = v[j];
        }
      } else if (t.tr == TransformInfo.palette) {
        final int first = t.beginC + 1;
        final int endC = t.beginC + t.numC - 1;
        final int last = endC + 1;
        final int bitDepth = ctx.bitDepth;
        final ModularChannel firstChannel = channels[first];
        final ModularChannel c0 = channels[0];
        for (int j = first + 1; j <= last; j++) {
          channels.insert(j, ModularChannel.copy(other: firstChannel));
        }
        for (var c = 0; c < t.numC; c++) {
          final ModularChannel chan = channels[first + c];
          final Int32List cb = chan.buffer!;
          for (var y = 0; y < firstChannel.height; y++) {
            for (var x = 0; x < firstChannel.width; x++) {
              final int o = y * firstChannel.width + x;
              int index = cb[o];
              final bool isDelta = index < t.nbDeltas;
              int value;
              if (index >= 0 && index < t.nbColors) {
                value = c0.get(c, index);
              } else if (index >= t.nbColors) {
                index -= t.nbColors;
                if (index < 64) {
                  value = ((index >> (2 * c)) % 4) * ((1 << bitDepth) - 1) ~/ 4 + (1 << (bitDepth - 3 > 0 ? bitDepth - 3 : 0));
                } else {
                  index -= 64;
                  for (var k = 0; k < c; k++) {
                    index ~/= 5;
                  }
                  value = (index % 5) * ((1 << bitDepth) - 1) ~/ 4;
                }
              } else if (c < 3) {
                index = (-index - 1) % 143;
                value = kDeltaPalette[((index + 1) >> 1) * 3 + c];
                if (index & 1 == 0) {
                  value = -value;
                }
                if (bitDepth > 8) {
                  value <<= (bitDepth < 24 ? bitDepth : 24) - 8;
                }
              } else {
                value = 0;
              }
              cb[o] = value;
              if (isDelta) {
                cb[o] += chan.prediction(y, x, t.dPred);
              }
            }
          }
        }
        channels.removeAt(0);
        if (t.beginC < nbMetaChannels) {
          nbMetaChannels -= 2 - t.numC;
        } else {
          nbMetaChannels--;
        }
      }
    }
  }
}
