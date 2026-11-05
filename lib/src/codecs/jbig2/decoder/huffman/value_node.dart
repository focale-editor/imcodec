// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 value node procedure.
class _Jbig2ValueNode extends _Jbig2Node {
  /// Stores range len.
  late final int _rangeLen;

  /// Stores range low.
  late final int _rangeLow;

  /// Stores is lower range.
  late final bool _isLowerRange;

  /// Creates the value node state.
  _Jbig2ValueNode({
    required _Jbig2Code c,
  }) {
    _rangeLen = c.rangeLength;
    _rangeLow = c.rangeLow;
    _isLowerRange = c.isLowerRange;
  }

  @override
  int decode(_Jbig2BitReader iis) {
    if (_isLowerRange) {
      /* B.4 4) */
      return (_rangeLow - iis.readBits(_rangeLen));
    } else {
      /* B.4 5) */
      return _rangeLow + iis.readBits(_rangeLen);
    }
  }

  /// Computes bit pattern.
  static String bitPattern(int v, int len) {
    final List<String> result = List<String>.filled(len, '');
    for (int i = 1; i <= len; i++) {
      result[i - 1] = (v >> (len - i) & 1) != 0 ? '1' : '0';
    }

    return result.join();
  }
}
