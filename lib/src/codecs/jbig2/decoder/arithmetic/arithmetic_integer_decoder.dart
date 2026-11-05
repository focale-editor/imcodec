// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 arithmetic integer decoder procedure.
class _Jbig2ArithmeticIntegerDecoder {
  /// Stores decoder.
  final _Jbig2ArithmeticDecoder decoder;

  /// Stores prev.
  int prev = 0;

  /// Creates the arithmetic integer decoder state.
  _Jbig2ArithmeticIntegerDecoder({
    required this.decoder,
  });

  /// Decodes the next value using the current context.
  int decode(_Jbig2ArithmeticContext? cxIAx) {
    int v = 0;
    int d;
    int s;

    int bitsToRead;
    int offset;

    final _Jbig2ArithmeticContext cx = cxIAx ?? _Jbig2ArithmeticContext(size: 512, index: 1);

    prev = 1;

    cx.setIndex(prev);
    s = decoder.decode(cx);
    setPrev(s);

    cx.setIndex(prev);
    d = decoder.decode(cx);
    setPrev(d);

    if (d == 1) {
      cx.setIndex(prev);
      d = decoder.decode(cx);
      setPrev(d);

      if (d == 1) {
        cx.setIndex(prev);
        d = decoder.decode(cx);
        setPrev(d);

        if (d == 1) {
          cx.setIndex(prev);
          d = decoder.decode(cx);
          setPrev(d);

          if (d == 1) {
            cx.setIndex(prev);
            d = decoder.decode(cx);
            setPrev(d);

            if (d == 1) {
              bitsToRead = 32;
              offset = 4436;
            } else {
              bitsToRead = 12;
              offset = 340;
            }
          } else {
            bitsToRead = 8;
            offset = 84;
          }
        } else {
          bitsToRead = 6;
          offset = 20;
        }
      } else {
        bitsToRead = 4;
        offset = 4;
      }
    } else {
      bitsToRead = 2;
      offset = 0;
    }

    for (int i = 0; i < bitsToRead; i++) {
      cx.setIndex(prev);
      d = decoder.decode(cx);
      setPrev(d);
      // `toSigned(32)` reproduz o transbordo do `int` de 32 bits da

      v = ((v << 1) | d).toSigned(32);
    }

    v = (v + offset).toSigned(32);

    if (s == 0) {
      return v;
    } else if (s == 1 && v > 0) {
      return -v;
    }

    return 0x1fffffffffffff;
  }

  /// Updates prev.
  void setPrev(int bit) {
    if (prev < 256) {
      prev = ((prev << 1) | bit) & 0x1ff;
    } else {
      prev = ((((prev << 1) | bit) & 511) | 256) & 0x1ff;
    }
  }

  /// Decodes iaid.
  int decodeIAID(_Jbig2ArithmeticContext cxIAID, int symCodeLen) {
    // A.3 1)
    prev = 1;

    // A.3 2)
    for (int i = 0; i < symCodeLen; i++) {
      cxIAID.setIndex(prev);
      prev = (prev << 1) | decoder.decode(cxIAID);
    }

    // A.3 3) & 4)
    return (prev - (1 << symCodeLen));
  }
}
