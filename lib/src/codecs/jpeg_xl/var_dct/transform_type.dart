import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Stores the llf scale table state used internally by the JPEG XL codec.
///
const _llfScaleTable = <double>[
  1.0000000000000000000, 1.0003954307206444720, 1.0015830492063566798, //
  1.0035668445359847378, 1.0063534990068075448, 1.0099524393750471170, //
  1.0143759095929498827, 1.0196390660646908181, 1.0257600967811994622, //
  1.0327603660498609462, 1.0406645869479269795, 1.0495010240726261235, //
  1.0593017296818027804, 1.0701028169146909598, 1.0819447744633102634, //
  1.0948728278735071820, 1.1089373535928257701, 1.1241943530045446156, //
  1.1407059950032801390, 1.1585412372562662921, 1.1777765381971696030, //
  1.1984966740821024139, 1.2207956782314713353, 1.2447779229495839992, //
  1.2705593687655135089, 1.2982690107340108228, 1.3280505578212198723, //
  1.3600643892400108061, 1.3944898413648201160, 1.4315278911623840964, //
  1.4714043176060183528, 1.5143734423313919909,
];

/// Processes the scale f data used by the JPEG XL codec.
///
double _scaleF(int x, int xll) => _llfScaleTable[x << (5 - xll)];

/// Transform (encoding) methods.
abstract final class TransformMethod {
  /// Stores the dct value used while processing JPEG XL data.
  ///
  static const dct = 0;

  /// Stores the dct2 value used while processing JPEG XL data.
  ///
  static const dct2 = 1;

  /// Stores the dct4 value used while processing JPEG XL data.
  ///
  static const dct4 = 2;

  /// Stores the hornuss value used while processing JPEG XL data.
  ///
  static const hornuss = 3;

  /// Stores the dct8x4 value used while processing JPEG XL data.
  ///
  static const dct8x4 = 4;

  /// Stores the dct4x8 value used while processing JPEG XL data.
  ///
  static const dct4x8 = 5;

  /// Stores the afv value used while processing JPEG XL data.
  ///
  static const afv = 6;
}

/// Quant-table encoding modes.
abstract final class TransformMode {
  /// Stores the library value used while processing JPEG XL data.
  ///
  static const library = 0;

  /// Stores the hornuss value used while processing JPEG XL data.
  ///
  static const hornuss = 1;

  /// Stores the dct2 value used while processing JPEG XL data.
  ///
  static const dct2 = 2;

  /// Stores the dct4 value used while processing JPEG XL data.
  ///
  static const dct4 = 3;

  /// Stores the dct4x8 value used while processing JPEG XL data.
  ///
  static const dct4x8 = 4;

  /// Stores the afv value used while processing JPEG XL data.
  ///
  static const afv = 5;

  /// Stores the dct value used while processing JPEG XL data.
  ///
  static const dct = 6;

  /// Stores the raw value used while processing JPEG XL data.
  ///
  static const raw = 7;
}

/// One of the 27 VarDCT transform types.
final class TransformType {
  /// Stores the name value used while processing JPEG XL data.
  ///
  final String name;

  /// Stores the type value used while processing JPEG XL data.
  ///
  final int type;

  /// Stores the parameter index value used while processing JPEG XL data.
  ///
  final int parameterIndex;

  /// Stores the order iD value used while processing JPEG XL data.
  ///
  final int orderID;

  /// Stores the transform method value used while processing JPEG XL data.
  ///
  final int transformMethod;

  /// Stores the pixel height value used while processing JPEG XL data.
  ///
  final int pixelHeight;

  /// Stores the pixel width value used while processing JPEG XL data.
  ///
  final int pixelWidth;

  /// Stores the dct select height value used while processing JPEG XL data.
  ///
  final int dctSelectHeight;

  /// Stores the dct select width value used while processing JPEG XL data.
  ///
  final int dctSelectWidth;

  /// Stores the matrix height value used while processing JPEG XL data.
  ///
  final int matrixHeight;

  /// Stores the matrix width value used while processing JPEG XL data.
  ///
  final int matrixWidth;

  /// [dctSelectHeight] x [dctSelectWidth] LLF scale factors, flattened.
  late final Float32List llfScale;

  /// Processes values information in a JPEG XL codestream.
  ///
  static final List<TransformType> values = _buildValues();

  /// Processes the by parameter index data used by the JPEG XL codec.
  ///
  static final List<TransformType> _byParameterIndex = () {
    final lookup = List<TransformType?>.filled(17, null);
    for (final TransformType t in values) {
      if (!t.isVertical) {
        lookup[t.parameterIndex] ??= t;
      }
    }
    return lookup.cast<TransformType>();
  }();

  /// Processes the by order id data used by the JPEG XL codec.
  ///
  static final List<TransformType> _byOrderID = () {
    final lookup = List<TransformType?>.filled(13, null);
    for (final TransformType t in values) {
      if (!t.isVertical) {
        lookup[t.orderID] ??= t;
      }
    }
    return lookup.cast<TransformType>();
  }();

  /// Creates Transform type state for JPEG XL processing.
  ///
  TransformType._({
    required this.name,
    required this.type,
    required this.parameterIndex,
    required this.orderID,
    required this.transformMethod,
    required this.pixelHeight,
    required this.pixelWidth,
  }) : dctSelectHeight = pixelHeight >> 3,
       dctSelectWidth = pixelWidth >> 3,
       matrixHeight = pixelHeight < pixelWidth ? pixelHeight : pixelWidth,
       matrixWidth = pixelHeight > pixelWidth ? pixelHeight : pixelWidth {
    llfScale = Float32List(dctSelectHeight * dctSelectWidth);
    final int yll = ceilLog2(dctSelectHeight);
    final int xll = ceilLog2(dctSelectWidth);
    for (var y = 0; y < dctSelectHeight; y++) {
      for (var x = 0; x < dctSelectWidth; x++) {
        llfScale[y * dctSelectWidth + x] = _scaleF(y, yll) * _scaleF(x, xll);
      }
    }
  }

  /// Stores the is vertical value used while processing JPEG XL data.
  ///
  bool get isVertical => pixelHeight > pixelWidth;

  /// Stores the flip value used while processing JPEG XL data.
  ///
  bool get flip => pixelHeight > pixelWidth || transformMethod == TransformMethod.dct && pixelHeight == pixelWidth;

  @override
  String toString() => name;

  /// Builds values.
  ///
  static List<TransformType> _buildValues() => [
    TransformType._(name: 'DCT 8x8', type: 0, parameterIndex: 0, orderID: 0, transformMethod: TransformMethod.dct, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'Hornuss', type: 1, parameterIndex: 1, orderID: 1, transformMethod: TransformMethod.hornuss, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 2x2', type: 2, parameterIndex: 2, orderID: 1, transformMethod: TransformMethod.dct2, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 4x4', type: 3, parameterIndex: 3, orderID: 1, transformMethod: TransformMethod.dct4, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 16x16', type: 4, parameterIndex: 4, orderID: 2, transformMethod: TransformMethod.dct, pixelHeight: 16, pixelWidth: 16),
    TransformType._(name: 'DCT 32x32', type: 5, parameterIndex: 5, orderID: 3, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 32),
    TransformType._(name: 'DCT 16x8', type: 6, parameterIndex: 6, orderID: 4, transformMethod: TransformMethod.dct, pixelHeight: 16, pixelWidth: 8),
    TransformType._(name: 'DCT 8x16', type: 7, parameterIndex: 6, orderID: 4, transformMethod: TransformMethod.dct, pixelHeight: 8, pixelWidth: 16),
    TransformType._(name: 'DCT 32x8', type: 8, parameterIndex: 7, orderID: 5, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 8),
    TransformType._(name: 'DCT 8x32', type: 9, parameterIndex: 7, orderID: 5, transformMethod: TransformMethod.dct, pixelHeight: 8, pixelWidth: 32),
    TransformType._(name: 'DCT 32x16', type: 10, parameterIndex: 8, orderID: 6, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 16),
    TransformType._(name: 'DCT 16x32', type: 11, parameterIndex: 8, orderID: 6, transformMethod: TransformMethod.dct, pixelHeight: 16, pixelWidth: 32),
    TransformType._(name: 'DCT 4x8', type: 12, parameterIndex: 9, orderID: 1, transformMethod: TransformMethod.dct4x8, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 8x4', type: 13, parameterIndex: 9, orderID: 1, transformMethod: TransformMethod.dct8x4, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV0', type: 14, parameterIndex: 10, orderID: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV1', type: 15, parameterIndex: 10, orderID: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV2', type: 16, parameterIndex: 10, orderID: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV3', type: 17, parameterIndex: 10, orderID: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 64x64', type: 18, parameterIndex: 11, orderID: 7, transformMethod: TransformMethod.dct, pixelHeight: 64, pixelWidth: 64),
    TransformType._(name: 'DCT 64x32', type: 19, parameterIndex: 12, orderID: 8, transformMethod: TransformMethod.dct, pixelHeight: 64, pixelWidth: 32),
    TransformType._(name: 'DCT 32x64', type: 20, parameterIndex: 12, orderID: 8, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 64),
    TransformType._(name: 'DCT 128x128', type: 21, parameterIndex: 13, orderID: 9, transformMethod: TransformMethod.dct, pixelHeight: 128, pixelWidth: 128),
    TransformType._(name: 'DCT 128x64', type: 22, parameterIndex: 14, orderID: 10, transformMethod: TransformMethod.dct, pixelHeight: 128, pixelWidth: 64),
    TransformType._(name: 'DCT 64x128', type: 23, parameterIndex: 14, orderID: 10, transformMethod: TransformMethod.dct, pixelHeight: 64, pixelWidth: 128),
    TransformType._(name: 'DCT 256x256', type: 24, parameterIndex: 15, orderID: 11, transformMethod: TransformMethod.dct, pixelHeight: 256, pixelWidth: 256),
    TransformType._(name: 'DCT 256x128', type: 25, parameterIndex: 16, orderID: 12, transformMethod: TransformMethod.dct, pixelHeight: 256, pixelWidth: 128),
    TransformType._(name: 'DCT 128x256', type: 26, parameterIndex: 16, orderID: 12, transformMethod: TransformMethod.dct, pixelHeight: 128, pixelWidth: 256),
  ];

  /// Processes by type information in a JPEG XL codestream.
  ///
  static TransformType byType(int typeIndex) => values[typeIndex];

  /// Processes by parameter index information in a JPEG XL codestream.
  ///
  static TransformType byParameterIndex(int parameterIndex) => _byParameterIndex[parameterIndex];

  /// Processes by order iD information in a JPEG XL codestream.
  ///
  static TransformType byOrderID(int orderID) => _byOrderID[orderID];

  /// Processes validate index information in a JPEG XL codestream.
  ///
  static void validateIndex(int index, int mode) {
    if (mode == TransformMode.library || mode == TransformMode.dct || mode == TransformMode.raw) {
      return;
    }
    if (index >= 0 && index <= 3 || index == 9 || index == 10) {
      return;
    }
    throw JpegXlInvalidBitstreamException(message: 'invalid index for mode: $index, $mode');
  }
}
