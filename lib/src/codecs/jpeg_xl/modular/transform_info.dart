import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Represents Squeeze param data used while processing JPEG XL images.
///
final class SqueezeParam {
  /// Stores the horizontal value used while processing JPEG XL data.
  ///
  final bool horizontal;

  /// Stores the in place value used while processing JPEG XL data.
  ///
  final bool inPlace;

  /// Stores the begin c value used while processing JPEG XL data.
  ///
  final int beginC;

  /// Stores the num c value used while processing JPEG XL data.
  ///
  final int numC;

  /// Creates Squeeze param data for JPEG XL processing.
  ///
  SqueezeParam({
    required this.horizontal,
    required this.inPlace,
    required this.beginC,
    required this.numC,
  });

  /// Processes read information in a JPEG XL codestream.
  ///
  SqueezeParam.read({
    required BitReader reader,
  }) : horizontal = reader.readBool(),
       inPlace = reader.readBool(),
       beginC = reader.readU32(0, 3, 8, 6, 72, 10, 1096, 13),
       numC = reader.readU32(1, 0, 2, 0, 3, 0, 4, 4);
}

/// One entry of a modular stream's transform chain.
final class TransformInfo {
  /// Stores the rct value used while processing JPEG XL data.
  ///
  static const rct = 0;

  /// Stores the palette value used while processing JPEG XL data.
  ///
  static const palette = 1;

  /// Stores the squeeze value used while processing JPEG XL data.
  ///
  static const squeeze = 2;

  /// Stores the tr value used while processing JPEG XL data.
  ///
  final int tr;

  /// Stores the begin c value used while processing JPEG XL data.
  ///
  final int beginC;

  /// Stores the rct type value used while processing JPEG XL data.
  ///
  final int rctType;

  /// Stores the num c value used while processing JPEG XL data.
  ///
  final int numC;

  /// Stores the nb colors value used while processing JPEG XL data.
  ///
  final int nbColors;

  /// Stores the nb deltas value used while processing JPEG XL data.
  ///
  final int nbDeltas;

  /// Stores the d pred value used while processing JPEG XL data.
  ///
  final int dPred;

  /// Stores the sp value used while processing JPEG XL data.
  ///
  final List<SqueezeParam>? sp;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory TransformInfo.read({
    required BitReader reader,
  }) {
    final int tr = reader.readBits(2);
    final int beginC = tr != squeeze ? reader.readU32(0, 3, 8, 6, 72, 10, 1096, 13) : 0;
    final int rctType = tr == rct ? reader.readU32(6, 0, 0, 2, 2, 4, 10, 6) : 0;
    var numC = 0;
    var nbColors = 0;
    var nbDeltas = 0;
    var dPred = 0;
    if (tr == palette) {
      numC = reader.readU32(1, 0, 3, 0, 4, 0, 1, 13);
      nbColors = reader.readU32(0, 8, 256, 10, 1280, 12, 5376, 16);
      nbDeltas = reader.readU32(0, 0, 1, 8, 257, 10, 1281, 16);
      dPred = reader.readBits(4);
    }
    List<SqueezeParam>? sp;
    if (tr == squeeze) {
      final int numSq = reader.readU32(0, 0, 1, 4, 9, 6, 41, 8);
      sp = List.generate(numSq, (_) => SqueezeParam.read(reader: reader));
    }
    return TransformInfo._(tr: tr, beginC: beginC, rctType: rctType, numC: numC, nbColors: nbColors, nbDeltas: nbDeltas, dPred: dPred, sp: sp);
  }

  /// Creates Transform info state for JPEG XL processing.
  ///
  TransformInfo._({
    required this.tr,
    required this.beginC,
    required this.rctType,
    required this.numC,
    required this.nbColors,
    required this.nbDeltas,
    required this.dPred,
    required this.sp,
  });
}
