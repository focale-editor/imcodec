import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';

/// Scale factors used for lowest-frequency coefficients by transform size.
const _lowestFrequencyScaleTable = <double>[
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

/// Returns the lowest-frequency scale for [position] at [logSize].
double _lowestFrequencyScale(int position, int logSize) => _lowestFrequencyScaleTable[position << (5 - logSize)];

/// Transform (encoding) methods.
abstract final class TransformMethod {
  /// Identifier selecting the DCT mode.
  static const int dct = 0;

  /// Identifier selecting the DCT 2 mode.
  static const int dct2 = 1;

  /// Identifier selecting the DCT 4 mode.
  static const int dct4 = 2;

  /// Identifier selecting the hornuss mode.
  static const int hornuss = 3;

  /// Identifier selecting the DCT 8x 4 mode.
  static const int dct8x4 = 4;

  /// Identifier selecting the DCT 4x 8 mode.
  static const int dct4x8 = 5;

  /// Identifier selecting the AFV mode.
  static const int afv = 6;
}

/// Quant-table encoding modes.
abstract final class TransformMode {
  /// Identifier selecting the library mode.
  static const int library = 0;

  /// Identifier selecting the hornuss mode.
  static const int hornuss = 1;

  /// Identifier selecting the DCT 2 mode.
  static const int dct2 = 2;

  /// Identifier selecting the DCT 4 mode.
  static const int dct4 = 3;

  /// Identifier selecting the DCT 4x 8 mode.
  static const int dct4x8 = 4;

  /// Identifier selecting the AFV mode.
  static const int afv = 5;

  /// Identifier selecting the DCT mode.
  static const int dct = 6;

  /// Identifier selecting the raw mode.
  static const int raw = 7;
}

/// One of the 27 VarDCT transform types.
final class TransformType {
  /// Name carried by the codestream.
  final String name;

  /// Type identifier defined by the JPEG XL specification.
  final int type;

  /// Index used to select quantization parameters.
  final int parameterIndex;

  /// Coefficient-order identifier defined by the JPEG XL specification.
  final int orderIdentifier;

  /// Core transform algorithm identifier.
  final int transformMethod;

  /// Pixel height in samples.
  final int pixelHeight;

  /// Pixel width in samples.
  final int pixelWidth;

  /// DCT select height in samples.
  final int dctSelectHeight;

  /// DCT select width in samples.
  final int dctSelectWidth;

  /// Matrix height in samples.
  final int matrixHeight;

  /// Matrix width in samples.
  final int matrixWidth;

  /// Flattened lowest-frequency scale factors for the selected DCT region.
  late final Float32List lowestFrequencyScale;

  /// All transform types indexed by their codestream type identifier.
  static final List<TransformType> values = _buildValues();

  /// Lookup from quantization-parameter index to a canonical orientation.
  static final List<TransformType> _byParameterIndex = () {
    final List<TransformType?> lookup = List<TransformType?>.filled(17, null);
    for (final TransformType transformType in values) {
      if (!transformType.isVertical) {
        lookup[transformType.parameterIndex] ??= transformType;
      }
    }
    return lookup.cast<TransformType>();
  }();

  /// Lookup from coefficient-order identifier to a canonical orientation.
  static final List<TransformType> _byOrderId = () {
    final List<TransformType?> lookup = List<TransformType?>.filled(13, null);
    for (final TransformType transformType in values) {
      if (!transformType.isVertical) {
        lookup[transformType.orderIdentifier] ??= transformType;
      }
    }
    return lookup.cast<TransformType>();
  }();

  /// Creates a transform type.
  TransformType._({
    required this.name,
    required this.type,
    required this.parameterIndex,
    required this.orderIdentifier,
    required this.transformMethod,
    required this.pixelHeight,
    required this.pixelWidth,
  }) : dctSelectHeight = pixelHeight >> 3,
       dctSelectWidth = pixelWidth >> 3,
       matrixHeight = pixelHeight < pixelWidth ? pixelHeight : pixelWidth,
       matrixWidth = pixelHeight > pixelWidth ? pixelHeight : pixelWidth {
    lowestFrequencyScale = Float32List(dctSelectHeight * dctSelectWidth);
    final int verticalLogSize = ceilLog2(dctSelectHeight);
    final int horizontalLogSize = ceilLog2(dctSelectWidth);
    for (int row = 0; row < dctSelectHeight; row++) {
      for (int column = 0; column < dctSelectWidth; column++) {
        lowestFrequencyScale[row * dctSelectWidth + column] = _lowestFrequencyScale(row, verticalLogSize) * _lowestFrequencyScale(column, horizontalLogSize);
      }
    }
  }

  /// Whether the transform is taller than it is wide.
  bool get isVertical => pixelHeight > pixelWidth;

  /// Whether coefficient rows and columns are transposed.
  bool get flip => pixelHeight > pixelWidth || transformMethod == TransformMethod.dct && pixelHeight == pixelWidth;

  @override
  String toString() => name;

  /// Builds transform metadata in codestream identifier order.
  static List<TransformType> _buildValues() => [
    TransformType._(name: 'DCT 8x8', type: 0, parameterIndex: 0, orderIdentifier: 0, transformMethod: TransformMethod.dct, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'Hornuss', type: 1, parameterIndex: 1, orderIdentifier: 1, transformMethod: TransformMethod.hornuss, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 2x2', type: 2, parameterIndex: 2, orderIdentifier: 1, transformMethod: TransformMethod.dct2, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 4x4', type: 3, parameterIndex: 3, orderIdentifier: 1, transformMethod: TransformMethod.dct4, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 16x16', type: 4, parameterIndex: 4, orderIdentifier: 2, transformMethod: TransformMethod.dct, pixelHeight: 16, pixelWidth: 16),
    TransformType._(name: 'DCT 32x32', type: 5, parameterIndex: 5, orderIdentifier: 3, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 32),
    TransformType._(name: 'DCT 16x8', type: 6, parameterIndex: 6, orderIdentifier: 4, transformMethod: TransformMethod.dct, pixelHeight: 16, pixelWidth: 8),
    TransformType._(name: 'DCT 8x16', type: 7, parameterIndex: 6, orderIdentifier: 4, transformMethod: TransformMethod.dct, pixelHeight: 8, pixelWidth: 16),
    TransformType._(name: 'DCT 32x8', type: 8, parameterIndex: 7, orderIdentifier: 5, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 8),
    TransformType._(name: 'DCT 8x32', type: 9, parameterIndex: 7, orderIdentifier: 5, transformMethod: TransformMethod.dct, pixelHeight: 8, pixelWidth: 32),
    TransformType._(name: 'DCT 32x16', type: 10, parameterIndex: 8, orderIdentifier: 6, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 16),
    TransformType._(name: 'DCT 16x32', type: 11, parameterIndex: 8, orderIdentifier: 6, transformMethod: TransformMethod.dct, pixelHeight: 16, pixelWidth: 32),
    TransformType._(name: 'DCT 4x8', type: 12, parameterIndex: 9, orderIdentifier: 1, transformMethod: TransformMethod.dct4x8, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 8x4', type: 13, parameterIndex: 9, orderIdentifier: 1, transformMethod: TransformMethod.dct8x4, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV0', type: 14, parameterIndex: 10, orderIdentifier: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV1', type: 15, parameterIndex: 10, orderIdentifier: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV2', type: 16, parameterIndex: 10, orderIdentifier: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'AFV3', type: 17, parameterIndex: 10, orderIdentifier: 1, transformMethod: TransformMethod.afv, pixelHeight: 8, pixelWidth: 8),
    TransformType._(name: 'DCT 64x64', type: 18, parameterIndex: 11, orderIdentifier: 7, transformMethod: TransformMethod.dct, pixelHeight: 64, pixelWidth: 64),
    TransformType._(name: 'DCT 64x32', type: 19, parameterIndex: 12, orderIdentifier: 8, transformMethod: TransformMethod.dct, pixelHeight: 64, pixelWidth: 32),
    TransformType._(name: 'DCT 32x64', type: 20, parameterIndex: 12, orderIdentifier: 8, transformMethod: TransformMethod.dct, pixelHeight: 32, pixelWidth: 64),
    TransformType._(name: 'DCT 128x128', type: 21, parameterIndex: 13, orderIdentifier: 9, transformMethod: TransformMethod.dct, pixelHeight: 128, pixelWidth: 128),
    TransformType._(name: 'DCT 128x64', type: 22, parameterIndex: 14, orderIdentifier: 10, transformMethod: TransformMethod.dct, pixelHeight: 128, pixelWidth: 64),
    TransformType._(name: 'DCT 64x128', type: 23, parameterIndex: 14, orderIdentifier: 10, transformMethod: TransformMethod.dct, pixelHeight: 64, pixelWidth: 128),
    TransformType._(name: 'DCT 256x256', type: 24, parameterIndex: 15, orderIdentifier: 11, transformMethod: TransformMethod.dct, pixelHeight: 256, pixelWidth: 256),
    TransformType._(name: 'DCT 256x128', type: 25, parameterIndex: 16, orderIdentifier: 12, transformMethod: TransformMethod.dct, pixelHeight: 256, pixelWidth: 128),
    TransformType._(name: 'DCT 128x256', type: 26, parameterIndex: 16, orderIdentifier: 12, transformMethod: TransformMethod.dct, pixelHeight: 128, pixelWidth: 256),
  ];

  /// Returns the entry selected by type.
  static TransformType byType(int typeIndex) => values[typeIndex];

  /// Returns the entry selected by parameter index.
  static TransformType byParameterIndex(int parameterIndex) => _byParameterIndex[parameterIndex];

  /// Returns the entry selected by coefficient-order identifier.
  static TransformType byOrderIdentifier(int orderIdentifier) => _byOrderId[orderIdentifier];

  /// Validates a quantization-table [index] for the selected encoding [mode].
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
