import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/blending_info.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// One patch: a rectangle of a reference frame blended at one or more
/// positions in the current frame.
final class Patch {
  /// Stores the reference-frame index.
  final int ref;

  /// Horizontal origin of the source rectangle.
  final int x;

  /// Vertical origin of the source rectangle.
  final int y;

  /// Width of the source rectangle.
  final int width;

  /// Height of the source rectangle.
  final int height;

  /// Target horizontal positions in the current frame.
  final List<int> positionsX;

  /// Target vertical positions in the current frame.
  final List<int> positionsY;

  /// Per-position, per-channel blending modes.
  final List<List<BlendingInfo>> blendingInfos;

  /// Creates Patch state for JPEG XL processing.
  ///
  Patch._({
    required this.ref,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.positionsX,
    required this.positionsY,
    required this.blendingInfos,
  });

  /// Processes read information in a JPEG XL codestream.
  ///
  factory Patch.read({
    required EntropyStream stream,
    required BitReader reader,
    required int extraChannelCount,
    required int alphaChannelCount,
  }) {
    final int ref = stream.readSymbol(reader, 1);
    final int x = stream.readSymbol(reader, 3);
    final int y = stream.readSymbol(reader, 3);
    final int width = 1 + stream.readSymbol(reader, 2);
    final int height = 1 + stream.readSymbol(reader, 2);
    final int count = 1 + stream.readSymbol(reader, 7);
    if (count <= 0) {
      throw const JpegXlInvalidBitstreamException(message: 'bad patch count');
    }
    final positionsX = List<int>.filled(count, 0);
    final positionsY = List<int>.filled(count, 0);
    final blendingInfos = <List<BlendingInfo>>[];
    for (var j = 0; j < count; j++) {
      if (j == 0) {
        positionsX[j] = stream.readSymbol(reader, 4);
        positionsY[j] = stream.readSymbol(reader, 4);
      } else {
        positionsX[j] = unpackSigned(stream.readSymbol(reader, 6)) + positionsX[j - 1];
        positionsY[j] = unpackSigned(stream.readSymbol(reader, 6)) + positionsY[j - 1];
      }
      final infos = <BlendingInfo>[];
      for (var k = 0; k < extraChannelCount + 1; k++) {
        final int mode = stream.readSymbol(reader, 5);
        var alpha = 0;
        var clamp = false;
        if (mode >= 8) {
          throw const JpegXlInvalidBitstreamException(message: 'illegal blending mode in patch');
        }
        if (mode > 3 && alphaChannelCount > 1) {
          alpha = stream.readSymbol(reader, 8);
          if (alpha >= extraChannelCount) {
            throw const JpegXlInvalidBitstreamException(message: 'patch alpha out of bounds');
          }
        }
        if (mode > 2) {
          clamp = stream.readSymbol(reader, 9) != 0;
        }
        infos.add(BlendingInfo.raw(mode: mode, alphaChannel: alpha, clamp: clamp, source: 0));
      }
      blendingInfos.add(infos);
    }
    return Patch._(ref: ref, x: x, y: y, width: width, height: height, positionsX: positionsX, positionsY: positionsY, blendingInfos: blendingInfos);
  }
}
