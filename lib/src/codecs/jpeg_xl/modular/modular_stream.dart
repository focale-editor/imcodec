import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/delta_palette.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/meta_adaptive_tree.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/modular_transform.dart';
import 'package:imcodec/src/codecs/jpeg_xl/modular/weighted_predictor_parameters.dart';

/// Permutation used to decode modular transform order.
const _permutationLut = [
  [0, 1, 2], [1, 2, 0], [2, 0, 1], //
  [0, 2, 1], [1, 0, 2], [2, 1, 0],
];

/// What a modular (sub-)stream needs to know about its enclosing frame.
final class ModularFrameContext {
  /// The modular frame size (frame bounds).
  final int frameWidth;

  /// Frame height in samples.
  final int frameHeight;

  /// Full-resolution coding-group dimension in pixels.
  final int groupDimension;

  /// Image-wide meta-adaptive tree, when the frame defines one.
  final MetaAdaptiveTree? globalTree;

  /// dimensionShift per extra channel.
  final List<int> extraChannelDimensionShifts;

  /// Image bits per sample (used by the palette transform).
  final int bitDepth;

  /// Creates a modular frame context.
  const ModularFrameContext({
    required this.frameWidth,
    required this.frameHeight,
    required this.groupDimension,
    required this.globalTree,
    required this.extraChannelDimensionShifts,
    required this.bitDepth,
  });
}

/// A modular bitstream section: channel list, transform chain, MA tree and
/// entropy stream, with forward parsing and inverse transform application.
final class ModularStream {
  /// Geometry and image metadata inherited from the enclosing frame.
  final ModularFrameContext context;

  /// Codestream identifier of this modular substream.
  final int streamIndex;

  /// Number of metadata channel entries in the modular stream.
  int metadataChannelCount = 0;

  /// Multiplier converting entropy distances to pixel-buffer offsets.
  int distanceMultiplier = 1;

  /// Meta-adaptive tree used to choose predictors and contexts.
  MetaAdaptiveTree? tree;

  /// Parameters used by self-correcting weighted prediction.
  WeightedPredictorParameters? weightedPredictorParameters;

  /// Transform chain applied before residual decoding.
  List<ModularTransform> transforms = const [];

  /// Entropy stream containing modular residuals.
  EntropyStream? stream;

  /// Whether inverse transforms have already been applied.
  bool _transformed = false;

  /// Channels decoded by this modular stream.
  final List<ModularChannel> channels = [];

  /// Original channel positions recorded for inverse squeeze transforms.
  final Map<int, List<SqueezeParameters>> _squeezeMap = {};

  /// Reads the stream header. If [channelArray] is given, those channels are
  /// used directly (group streams); otherwise [channelCount] full-frame
  /// channels are created, of which the last `channelCount - ecStart` are
  /// extra channels.
  ModularStream.read({
    required BitReader reader,
    required this.context,
    required this.streamIndex,
    List<ModularChannel>? channelArray,
    int channelCount = 0,
    int ecStart = 0,
  }) {
    final int effectiveChannelCount = channelArray?.length ?? channelCount;
    if (effectiveChannelCount == 0) {
      distanceMultiplier = 1;
      return;
    }
    final bool useGlobalTree = reader.readBool();
    weightedPredictorParameters = WeightedPredictorParameters.read(reader: reader);
    final int transformCount = reader.readU32(0, 0, 1, 0, 2, 4, 18, 8);
    transforms = List.generate(transformCount, (_) => ModularTransform.read(reader: reader));

    if (channelArray == null) {
      for (var i = 0; i < channelCount; i++) {
        final int dimensionShift = i < ecStart ? 0 : context.extraChannelDimensionShifts[i - ecStart];
        channels.add(ModularChannel(height: context.frameHeight, width: context.frameWidth, verticalShift: dimensionShift, horizontalShift: dimensionShift));
      }
    } else {
      channels.addAll(channelArray);
    }

    for (var i = 0; i < transformCount; i++) {
      final ModularTransform transform = transforms[i];
      if (transform.type == ModularTransform.palette || transform.type == ModularTransform.reversibleColor) {
        final int needed = transform.type == ModularTransform.reversibleColor ? 3 : transform.channelCount;
        if (transform.firstChannel < 0 || needed < 1 || transform.firstChannel + needed > channels.length) {
          throw const JpegXlInvalidBitstreamException(message: 'transform channel range out of bounds');
        }
      }
      if (transform.type == ModularTransform.palette) {
        if (transform.firstChannel < metadataChannelCount) {
          metadataChannelCount += 2 - transform.channelCount;
        } else {
          metadataChannelCount++;
        }
        final int start = transform.firstChannel + 1;
        for (var j = start; j < transform.firstChannel + transform.channelCount; j++) {
          channels.removeAt(start);
        }
        if (transform.deltaCount > 0 && transform.deltaPredictor == 6) {
          channels[transform.firstChannel].forceWeightedPredictor = true;
        }
        channels.insert(0, ModularChannel(height: transform.channelCount, width: transform.colorCount, verticalShift: -1, horizontalShift: -1));
      } else if (transform.type == ModularTransform.squeeze) {
        final squeezeList = <SqueezeParameters>[];
        if (transform.squeezeParameters!.isEmpty) {
          final int first = metadataChannelCount;
          final int count = channels.length - first;
          // Default squeeze parameters operate on the first non-meta
          // channel's size (libjxl uses channel[nb_meta_channels]).
          int w = channels[first].width;
          int h = channels[first].height;
          if (count > 2 && channels[first + 1].sizeEquals(channels[first])) {
            squeezeList.add(SqueezeParameters(horizontal: true, inPlace: false, firstChannel: first + 1, channelCount: 2));
            squeezeList.add(SqueezeParameters(horizontal: false, inPlace: false, firstChannel: first + 1, channelCount: 2));
          }
          if (h >= w && h > 8) {
            squeezeList.add(SqueezeParameters(horizontal: false, inPlace: true, firstChannel: first, channelCount: count));
            h = (h + 1) ~/ 2;
          }
          while (w > 8 || h > 8) {
            if (w > 8) {
              squeezeList.add(SqueezeParameters(horizontal: true, inPlace: true, firstChannel: first, channelCount: count));
              w = (w + 1) ~/ 2;
            }
            if (h > 8) {
              squeezeList.add(SqueezeParameters(horizontal: false, inPlace: true, firstChannel: first, channelCount: count));
              h = (h + 1) ~/ 2;
            }
          }
        } else {
          squeezeList.addAll(transform.squeezeParameters!);
        }
        _squeezeMap[i] = squeezeList;
        for (final SqueezeParameters squeeze in squeezeList) {
          final int begin = squeeze.firstChannel;
          final int end = begin + squeeze.channelCount - 1;
          if (begin < 0 || squeeze.channelCount < 1 || end >= channels.length) {
            throw const JpegXlInvalidBitstreamException(message: 'squeeze channel range out of bounds');
          }
          final int offset = squeeze.inPlace ? end + 1 : channels.length;
          if (begin < metadataChannelCount) {
            if (!squeeze.inPlace) {
              throw const JpegXlInvalidBitstreamException(message: 'squeeze meta must be in place');
            }
            if (end >= metadataChannelCount) {
              throw const JpegXlInvalidBitstreamException(message: 'squeeze meta must end in meta');
            }
            metadataChannelCount += squeeze.channelCount;
          }
          for (var k = begin; k <= end; k++) {
            final ModularChannel chan = channels[k];
            final int r = offset + k - begin;
            final ModularChannel residu;
            if (squeeze.horizontal) {
              final int w = chan.width;
              chan.width = (w + 1) ~/ 2;
              chan.horizontalShift++;
              residu = ModularChannel.copy(other: chan);
              residu.width = w ~/ 2;
            } else {
              final int h = chan.height;
              chan.height = (h + 1) ~/ 2;
              chan.verticalShift++;
              residu = ModularChannel.copy(other: chan);
              residu.height = h ~/ 2;
            }
            channels.insert(r, residu);
          }
        }
      } else if (transform.type == ModularTransform.reversibleColor) {
        // RCT doesn'transform modify the channel list.
        continue;
      } else {
        throw JpegXlInvalidBitstreamException(message: 'illegal transform ${transform.type}');
      }
    }

    if (!useGlobalTree) {
      tree = MetaAdaptiveTree.read(reader: reader);
    } else {
      tree = context.globalTree;
      if (tree == null) {
        throw const JpegXlInvalidBitstreamException(message: 'stream uses global tree but no global tree exists');
      }
    }
    stream = EntropyStream.clone(other: tree!.stream!);

    distanceMultiplier = 0;
    for (final ModularChannel c in channels) {
      if (c.width > distanceMultiplier) {
        distanceMultiplier = c.width;
      }
    }
  }

  /// Number of encoded channel entries in the modular stream.
  int get encodedChannelCount => channels.length;

  /// Whether this stream applies a Squeeze (responsive) transform — the
  /// precondition for the decoder's low-res Squeeze downscale path.
  bool get usesSqueeze => transforms.any((transform) => transform.type == ModularTransform.squeeze);

  /// Returns the decoded channel at [index].
  ModularChannel getChannel(int index) => channels[index];

  /// Decodes channels.
  void decodeChannels(BitReader reader, {bool partial = false}) {
    var channelIndex = 0;
    for (var i = 0; i < channels.length; i++) {
      final ModularChannel channel = channels[i];
      if (partial && i >= metadataChannelCount && (channel.height > context.groupDimension || channel.width > context.groupDimension)) {
        break;
      }
      if (channel.width == 0 || channel.height == 0) {
        channel.allocate();
      } else {
        channel.decode(reader, stream!, weightedPredictorParameters, tree!, channels, channelIndex, streamIndex, distanceMultiplier);
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

  /// Applies the decoded modular transforms.
  void applyTransforms() {
    if (_transformed) {
      return;
    }
    _transformed = true;
    for (int i = transforms.length - 1; i >= 0; i--) {
      final ModularTransform transform = transforms[i];
      if (transform.type == ModularTransform.squeeze) {
        final List<SqueezeParameters> squeezeParametersList = _squeezeMap[i]!;
        for (int j = squeezeParametersList.length - 1; j >= 0; j--) {
          final SqueezeParameters squeeze = squeezeParametersList[j];
          final int begin = squeeze.firstChannel;
          final int end = begin + squeeze.channelCount - 1;
          final int offset = squeeze.inPlace ? end + 1 : channels.length + begin - end - 1;
          for (var c = begin; c <= end; c++) {
            final int r = offset + c - begin;
            final ModularChannel chan = channels[c];
            final ModularChannel residu = channels[r];
            final ModularChannel output;
            if (squeeze.horizontal) {
              output = ModularChannel.inverseHorizontalSqueeze(
                ModularChannel(height: chan.height, width: chan.width + residu.width, verticalShift: chan.verticalShift, horizontalShift: chan.horizontalShift - 1),
                chan,
                residu,
              );
            } else {
              output = ModularChannel.inverseVerticalSqueeze(
                ModularChannel(height: chan.height + residu.height, width: chan.width, verticalShift: chan.verticalShift - 1, horizontalShift: chan.horizontalShift),
                chan,
                residu,
              );
            }
            channels[c] = output;
          }
          for (var c = 0; c < end - begin + 1; c++) {
            channels.removeAt(offset);
          }
        }
      } else if (transform.type == ModularTransform.reversibleColor) {
        final int permutation = transform.reversibleColorTransformType ~/ 7;
        final int type = transform.reversibleColorTransformType % 7;
        if (permutation >= _permutationLut.length) {
          throw const JpegXlInvalidBitstreamException(message: 'invalid RCT permutation');
        }
        final int start = transform.firstChannel;
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
      } else if (transform.type == ModularTransform.palette) {
        final int first = transform.firstChannel + 1;
        final int endC = transform.firstChannel + transform.channelCount - 1;
        final int last = endC + 1;
        final int bitDepth = context.bitDepth;
        final ModularChannel firstChannel = channels[first];
        final ModularChannel c0 = channels[0];
        for (int j = first + 1; j <= last; j++) {
          channels.insert(j, ModularChannel.copy(other: firstChannel));
        }
        for (var c = 0; c < transform.channelCount; c++) {
          final ModularChannel chan = channels[first + c];
          final Int32List cb = chan.buffer!;
          for (var y = 0; y < firstChannel.height; y++) {
            for (var x = 0; x < firstChannel.width; x++) {
              final int o = y * firstChannel.width + x;
              int index = cb[o];
              final bool isDelta = index < transform.deltaCount;
              int value;
              if (index >= 0 && index < transform.colorCount) {
                value = c0.sampleAt(c, index);
              } else if (index >= transform.colorCount) {
                index -= transform.colorCount;
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
                cb[o] += chan.prediction(y, x, transform.deltaPredictor);
              }
            }
          }
        }
        channels.removeAt(0);
        if (transform.firstChannel < metadataChannelCount) {
          metadataChannelCount -= 2 - transform.channelCount;
        } else {
          metadataChannelCount--;
        }
      }
    }
  }
}
