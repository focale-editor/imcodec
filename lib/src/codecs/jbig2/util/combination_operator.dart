// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Specifies the JBIG2 combination operator.
enum _Jbig2CombinationOperator {
  /// Applies the or operation.
  or,

  /// Applies the and operation.
  and,

  /// Applies the xor operation.
  xor,

  /// Applies the xnor operation.
  xnor,

  /// Applies the replace operation.
  replace;

  /// Computes translate operator code to enum.
  static _Jbig2CombinationOperator translateOperatorCodeToEnum(int combinationOperatorCode) {
    switch (combinationOperatorCode) {
      case 0:
        return or;
      case 1:
        return and;
      case 2:
        return xor;
      case 3:
        return xnor;
      default:
        return replace;
    }
  }
}
