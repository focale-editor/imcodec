import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/toc.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/var_dct/transform_type.dart';

/// Natural coefficient orders per orderID, as packed (y << 16 | x) values.
final List<Int32List?> _naturalOrderCache = List.filled(13, null);

/// Public so the lossy encoder can scan coefficients in the exact same
/// (cached) order the decoder reads them in.
Int32List getNaturalOrder(int i) {
  final Int32List? cached = _naturalOrderCache[i];
  if (cached != null) {
    return cached;
  }
  final TransformType tt = TransformType.byOrderID(i);
  final int len = tt.pixelHeight * tt.pixelWidth;
  final coords = List<int>.generate(len, (j) {
    final int y = j ~/ tt.pixelWidth;
    final int x = j % tt.pixelWidth;
    return (y << 16) | x;
  });
  final int maxDim = tt.dctSelectHeight > tt.dctSelectWidth ? tt.dctSelectHeight : tt.dctSelectWidth;
  coords.sort((a, b) {
    final int ay = a >> 16;
    final int ax = a & 0xFFFF;
    final int by = b >> 16;
    final int bx = b & 0xFFFF;
    final bool aLLF = ay < tt.dctSelectHeight && ax < tt.dctSelectWidth;
    final bool bLLF = by < tt.dctSelectHeight && bx < tt.dctSelectWidth;
    if (aLLF && !bLLF) {
      return -1;
    }
    if (bLLF && !aLLF) {
      return 1;
    }
    if (aLLF && bLLF) {
      if (by != ay) {
        return ay - by;
      }
      return ax - bx;
    }
    final int aSY = ay * maxDim ~/ tt.dctSelectHeight;
    final int aSX = ax * maxDim ~/ tt.dctSelectWidth;
    final int bSY = by * maxDim ~/ tt.dctSelectHeight;
    final int bSX = bx * maxDim ~/ tt.dctSelectWidth;
    final int aKey1 = aSY + aSX;
    final int bKey1 = bSY + bSX;
    if (aKey1 != bKey1) {
      return aKey1 - bKey1;
    }
    int aKey2 = aSX - aSY;
    int bKey2 = bSX - bSY;
    if (aKey1 & 1 == 1) {
      aKey2 = -aKey2;
    }
    if (bKey1 & 1 == 1) {
      bKey2 = -bKey2;
    }
    return aKey2 - bKey2;
  });
  return _naturalOrderCache[i] = Int32List.fromList(coords);
}

/// Per-pass VarDCT data: coefficient orders and the shared AC context
/// entropy stream.
final class HfPass {
  /// Stores the used orders value used while processing JPEG XL data.
  ///
  late final int usedOrders;

  /// Processes the order data used by the JPEG XL codec.
  ///
  final List<List<Int32List>?> _order = List.filled(13, null);

  /// Stores the context stream value used while processing JPEG XL data.
  ///
  late final EntropyStream contextStream;

  /// Creates Hf pass data for JPEG XL processing.
  ///
  HfPass({
    required BitReader reader,
    required Frame frame,
    required int passIndex,
  }) {
    usedOrders = reader.readU32(0x5F, 0, 0x13, 0, 0, 0, 0, 13);
    final EntropyStream? stream = usedOrders != 0 ? EntropyStream.read(reader: reader, numDists: 8) : null;
    // Permuted orders must be read from the bitstream now; natural orders
    // for unused IDs are built lazily on first use (the big zigzag sorts
    // are expensive and most images touch only a few transform types).
    for (var b = 0; b < 13; b++) {
      if (usedOrders & (1 << b) == 0) {
        continue;
      }
      final Int32List naturalOrder = getNaturalOrder(b);
      final int len = naturalOrder.length;
      _order[b] = List.generate(3, (c) {
        final List<int> perm = readPermutation(reader, stream!, len, len ~/ 64);
        final o = Int32List(len);
        for (var i = 0; i < len; i++) {
          o[i] = naturalOrder[perm[i]];
        }
        return o;
      }, growable: false);
    }
    if (stream != null && !stream.validateFinalState()) {
      throw JpegXlInvalidBitstreamException(message: 'ANS state decoding HFPass perms: $passIndex');
    }
    final int numContexts = 495 * frame.hfGlobal!.numHfPresets * frame.lfGlobal.hfBlockCtx!.numClusters;
    contextStream = EntropyStream.read(reader: reader, numDists: numContexts);
  }

  /// orderFor(orderID)[channel] -> packed (y << 16 | x) coefficient
  /// positions.
  List<Int32List> orderFor(int orderID) {
    final List<Int32List>? cached = _order[orderID];
    if (cached != null) {
      return cached;
    }
    final Int32List naturalOrder = getNaturalOrder(orderID);
    return _order[orderID] = List.filled(3, naturalOrder, growable: false);
  }
}
