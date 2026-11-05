// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 end of stripe procedure.
class _Jbig2EndOfStripe implements _Jbig2SegmentData {
  /// Stores sub input stream.
  late _Jbig2BitReader subInputStream;

  /// Stores line number.
  int lineNumber = 0;

  @override
  void init(_Jbig2Segment? header, _Jbig2BitReader sis) {
    subInputStream = sis;
    parseHeader();
  }

  /// Parses header.
  void parseHeader() {
    lineNumber = subInputStream.readBits(32) & 0xffffffff;
  }

  /// Returns line number.
  int getLineNumber() => lineNumber;
}
