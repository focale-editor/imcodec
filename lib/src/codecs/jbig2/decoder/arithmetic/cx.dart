// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 arithmetic context procedure.
class _Jbig2ArithmeticContext {
  /// Stores index.
  int index;

  /// Adaptive arithmetic state for the CX LIST context.
  final Uint8List cxList;

  /// Stores mps list.
  final Uint8List mpsList;

  /// Creates the arithmetic context state.
  _Jbig2ArithmeticContext({
    required int size,
    required this.index,
  }) : cxList = Uint8List(_Jbig2Budget.reserve(size, 2)),
       mpsList = Uint8List(size);

  /// Computes cx.
  int cx() => cxList[index] & 0x7f;

  /// Updates cx.
  void setCx(int value) {
    cxList[index] = value & 0x7f;
  }

  /// Computes mps.
  int mps() => mpsList[index];

  /// Computes toggle mps.
  void toggleMps() {
    mpsList[index] ^= 1;
  }

  /// Returns index.
  int getIndex() => index;

  /// Updates index.
  void setIndex(int index) {
    this.index = index;
  }
}
