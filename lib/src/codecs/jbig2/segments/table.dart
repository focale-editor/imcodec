// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 table procedure.
class _Jbig2Table implements _Jbig2SegmentData {
  /// Stores sub input stream.
  late _Jbig2BitReader subInputStream;

  /// Stores ht out of band.
  int _htOutOfBand = 0;

  /// Stores ht ps.
  int _htPS = 0;

  /// Stores ht rs.
  int _htRS = 0;

  /// Stores ht low.
  int _htLow = 0;

  /// Stores ht high.
  int _htHigh = 0;

  /// Parses header.
  void _parseHeader() {
    int bit;

    /* Bit 7 */
    if ((bit = subInputStream.readBit()) == 1) {
      throw FormatException('B.2.1 _Jbig2Code table flags: Bit 7 must be zero, but was $bit');
    }

    /* Bit 4-6 */
    _htRS = (subInputStream.readBits(3) + 1) & 0xf;

    /* Bit 1-3 */
    _htPS = (subInputStream.readBits(3) + 1) & 0xf;

    /* Bit 0 */
    _htOutOfBand = subInputStream.readBit();

    _htLow = _toSigned32(subInputStream.readBits(32));
    _htHigh = _toSigned32(subInputStream.readBits(32));
  }

  /// Computes to signed32.
  int _toSigned32(int val) {
    if (val >= 0x80000000) {
      return val - 0x100000000;
    }
    return val;
  }

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    subInputStream = sis;
    _parseHeader();
  }

  /// Returns ht oob.
  int get htOOB => _htOutOfBand;

  /// Returns ht ps.
  int get htPS => _htPS;

  /// Returns ht rs.
  int get htRS => _htRS;

  /// Returns ht low.
  int get htLow => _htLow;

  /// Returns ht high.
  int get htHigh => _htHigh;
}
