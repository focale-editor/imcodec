// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Implements the JBIG2 bitmaps procedure.
class _Jbig2Bitmaps {
  /// Computes extract.
  static _Jbig2Bitmap extract(_Jbig2Rectangle roi, _Jbig2Bitmap src) {
    final _Jbig2Bitmap dst = _Jbig2Bitmap(width: roi.width, height: roi.height);

    final int upShift = roi.x & 0x07;
    final int downShift = 8 - upShift;
    int dstLineStartIdx = 0;

    final int padding = (8 - dst.width & 0x07);
    int srcLineStartIdx = src.getByteIndex(roi.x, roi.y);
    int srcLineEndIdx = src.getByteIndex(roi.x + roi.width - 1, roi.y);
    final bool usePadding = dst.rowStride == srcLineEndIdx + 1 - srcLineStartIdx;

    for (int y = roi.y; y < roi.maxY; y++) {
      int srcIdx = srcLineStartIdx;
      int dstIdx = dstLineStartIdx;

      if (srcLineStartIdx == srcLineEndIdx) {
        final int pixels = (src.getByte(srcIdx) << upShift) & 0xFF;
        dst.setByte(dstIdx, unpad(padding, pixels));
      } else if (upShift == 0) {
        for (int x = srcLineStartIdx; x <= srcLineEndIdx; x++) {
          int value = src.getByte(srcIdx++);

          if (x == srcLineEndIdx && usePadding) {
            value = unpad(padding, value);
          }

          dst.setByte(dstIdx++, value);
        }
      } else {
        copyLine(src, dst, upShift, downShift, padding, srcLineStartIdx, srcLineEndIdx, usePadding, srcIdx, dstIdx);
      }

      srcLineStartIdx += src.rowStride;
      srcLineEndIdx += src.rowStride;
      dstLineStartIdx += dst.rowStride;
    }

    return dst;
  }

  /// Copies line.
  static void copyLine(
    _Jbig2Bitmap src,
    _Jbig2Bitmap dst,
    int sourceUpShift,
    int sourceDownShift,
    int padding,
    int firstSourceByteOfLine,
    int lastSourceByteOfLine,
    bool usePadding,
    int initialSourceOffset,
    int initialTargetOffset,
  ) {
    int targetOffset = initialTargetOffset;
    int sourceOffset = initialSourceOffset;
    for (int x = firstSourceByteOfLine; x < lastSourceByteOfLine; x++) {
      if (sourceOffset + 1 < src.getByteArray().length) {
        final bool isLastByte = x + 1 == lastSourceByteOfLine;
        final int val1 = (src.getByte(sourceOffset++) << sourceUpShift) & 0xFF;
        final int val2 = (src.getByte(sourceOffset) & 0xFF) >> sourceDownShift;
        int value = (val1 | val2) & 0xFF;

        if (isLastByte && !usePadding) {
          value = unpad(padding, value);
        }

        dst.setByte(targetOffset++, value);

        if (isLastByte && usePadding) {
          value = unpad(padding, ((src.getByte(sourceOffset) & 0xFF) << sourceUpShift) & 0xFF);
          dst.setByte(targetOffset, value);
        }
      } else {
        final int value = (src.getByte(sourceOffset++) << sourceUpShift) & 0xFF;
        dst.setByte(targetOffset++, value);
      }
    }
  }

  /// Computes combine bytes.
  static int combineBytes(int value1, int value2, _Jbig2CombinationOperator op) {
    switch (op) {
      case _Jbig2CombinationOperator.or:
        return (value2 | value1) & 0xff;
      case _Jbig2CombinationOperator.and:
        return (value2 & value1) & 0xff;
      case _Jbig2CombinationOperator.xor:
        return (value2 ^ value1) & 0xff;
      case _Jbig2CombinationOperator.xnor:
        return ~(value1 ^ value2) & 0xff;
      case _Jbig2CombinationOperator.replace:
        return value2;
    }
  }

  /// Combines one pixel the way [combineBytes] combines eight of them.
  static int combinePixels(int value1, int value2, _Jbig2CombinationOperator op) {
    switch (op) {
      case _Jbig2CombinationOperator.or:
        return value1 | value2;
      case _Jbig2CombinationOperator.and:
        return value1 & value2;
      case _Jbig2CombinationOperator.xor:
        return value1 ^ value2;
      case _Jbig2CombinationOperator.xnor:
        return (value1 ^ value2) ^ 1;
      case _Jbig2CombinationOperator.replace:
        return value2;
    }
  }

  /// True when combining a source pixel of 0 leaves the destination alone.
  ///
  /// The byte-wide routines below write whole destination bytes, so the zero
  /// bits that pad the last byte of a source row, and the bits a shifted row
  /// does not cover, reach the destination as if they were part of the
  /// region. That is harmless for or and xor, whose identity element is 0, and
  /// wrong for every other operator of 7.4.1.5 — those go through
  /// [blitPixelwise] instead.
  static bool _zeroIsIdentity(_Jbig2CombinationOperator op) => op == _Jbig2CombinationOperator.or || op == _Jbig2CombinationOperator.xor;

  /// True when the whole of [src] lands inside [dst] at ([x], [y]).
  static bool _fitsInside(_Jbig2Bitmap src, _Jbig2Bitmap dst, int x, int y) => x >= 0 && y >= 0 && x + src.width <= dst.width && y + src.height <= dst.height;

  /// Combines [src] into [dst] at ([x], [y]) one pixel at a time, touching
  /// nothing outside the source rectangle.
  static void blitPixelwise(_Jbig2Bitmap src, _Jbig2Bitmap dst, int x, int y, _Jbig2CombinationOperator op) {
    for (int line = 0; line < src.height; line++) {
      final int targetY = y + line;
      if (targetY < 0 || targetY >= dst.height) {
        continue;
      }
      for (int column = 0; column < src.width; column++) {
        final int targetX = x + column;
        if (targetX < 0 || targetX >= dst.width) {
          continue;
        }
        dst.writePixel(targetX, targetY, combinePixels(dst.getPixel(targetX, targetY), src.getPixel(column, line), op));
      }
    }
  }

  /// Computes blit.
  static void blit(_Jbig2Bitmap src, _Jbig2Bitmap dst, int initialX, int initialY, _Jbig2CombinationOperator combinationOperator) {
    int y = initialY;
    int x = initialX;
    if (!_zeroIsIdentity(combinationOperator) || !_fitsInside(src, dst, x, y)) {
      // The byte-wide routines below index whole bytes, so they can only clip
      // a placement that starts and ends on the destination. A partial one --
      // a halftone grid whose origin is negative, say -- has to go pixel by
      // pixel, or the row offset would be read as a byte offset and the
      // pattern would land eight times too far to the left.
      blitPixelwise(src, dst, x, y, combinationOperator);
      return;
    }

    int startLine = 0;
    int srcStartIdx = 0;
    int srcEndIdx = (src.rowStride - 1);

    // Ignore those parts of the source bitmap which would be placed outside the target bitmap.
    if (x < 0) {
      srcStartIdx = -x;
      x = 0;
    } else if (x + src.width > dst.width) {
      srcEndIdx -= (src.width + x - dst.width);
    }

    if (y < 0) {
      startLine = -y;
      y = 0;
      srcStartIdx += src.rowStride;
      srcEndIdx += src.rowStride;
    } else if (y + src.height > dst.height) {
      startLine = src.height + y - dst.height;
    }

    final int shiftVal1 = x & 0x07;
    final int shiftVal2 = 8 - shiftVal1;

    final int padding = src.width & 0x07;
    final int toShift = shiftVal2 - padding;

    final bool useShift = (shiftVal2 & 0x07) != 0;
    final bool specialCase = src.width <= ((srcEndIdx - srcStartIdx) << 3) + shiftVal2;

    final int dstStartIdx = dst.getByteIndex(x, y);

    final int lastLine = math.min(src.height, startLine + dst.height);

    if (!useShift) {
      blitUnshifted(src, dst, startLine, lastLine, dstStartIdx, srcStartIdx, srcEndIdx, combinationOperator);
    } else if (specialCase) {
      blitSpecialShifted(src, dst, startLine, lastLine, dstStartIdx, srcStartIdx, srcEndIdx, toShift, shiftVal1, shiftVal2, combinationOperator);
    } else {
      blitShifted(src, dst, startLine, lastLine, dstStartIdx, srcStartIdx, srcEndIdx, toShift, shiftVal1, shiftVal2, combinationOperator, padding);
    }
  }

  /// Computes blit unshifted.
  static void blitUnshifted(_Jbig2Bitmap src, _Jbig2Bitmap dst, int startLine, int lastLine, int initialDstStartIdx, int initialSrcStartIdx, int initialSrcEndIdx, _Jbig2CombinationOperator op) {
    int srcEndIdx = initialSrcEndIdx;
    int srcStartIdx = initialSrcStartIdx;
    int dstStartIdx = initialDstStartIdx;
    for (int dstLine = startLine; dstLine < lastLine; dstLine++, dstStartIdx += dst.rowStride, srcStartIdx += src.rowStride, srcEndIdx += src.rowStride) {
      int dstIdx = dstStartIdx;

      // Go through the bytes in a line of the Symbol
      for (int srcIdx = srcStartIdx; srcIdx <= srcEndIdx; srcIdx++) {
        final int oldByte = dst.getByte(dstIdx);
        final int newByte = src.getByte(srcIdx);
        dst.setByte(dstIdx++, combineBytes(oldByte, newByte, op));
      }
    }
  }

  /// Computes blit special shifted.
  static void blitSpecialShifted(
    _Jbig2Bitmap src,
    _Jbig2Bitmap dst,
    int startLine,
    int lastLine,
    int initialDstStartIdx,
    int initialSrcStartIdx,
    int initialSrcEndIdx,
    int toShift,
    int shiftVal1,
    int shiftVal2,
    _Jbig2CombinationOperator op,
  ) {
    int srcEndIdx = initialSrcEndIdx;
    int srcStartIdx = initialSrcStartIdx;
    int dstStartIdx = initialDstStartIdx;
    for (int dstLine = startLine; dstLine < lastLine; dstLine++, dstStartIdx += dst.rowStride, srcStartIdx += src.rowStride, srcEndIdx += src.rowStride) {
      int register = 0;
      int dstIdx = dstStartIdx;

      // Go through the bytes in a line of the Symbol
      for (int srcIdx = srcStartIdx; srcIdx <= srcEndIdx; srcIdx++) {
        final int oldByte = dst.getByte(dstIdx);
        register = ((register | src.getByte(srcIdx)) << shiftVal2) & 0xffff; // Keep it within reasonable bounds, though int is 64bit
        int newByte = (register >> 8) & 0xff;

        if (srcIdx == srcEndIdx) {
          newByte = unpad(toShift, newByte);
        }

        dst.setByte(dstIdx++, combineBytes(oldByte, newByte, op));
        register <<= shiftVal1;
        register &= 0xffff; // Mask to simulate short behavior if needed, but here we just need bits
      }
    }
  }

  /// Computes blit shifted.
  static void blitShifted(
    _Jbig2Bitmap src,
    _Jbig2Bitmap dst,
    int startLine,
    int lastLine,
    int initialDstStartIdx,
    int initialSrcStartIdx,
    int initialSrcEndIdx,
    int toShift,
    int shiftVal1,
    int shiftVal2,
    _Jbig2CombinationOperator op,
    int padding,
  ) {
    int srcEndIdx = initialSrcEndIdx;
    int srcStartIdx = initialSrcStartIdx;
    int dstStartIdx = initialDstStartIdx;
    for (int dstLine = startLine; dstLine < lastLine; dstLine++, dstStartIdx += dst.rowStride, srcStartIdx += src.rowStride, srcEndIdx += src.rowStride) {
      int register = 0;
      int dstIdx = dstStartIdx;

      // Go through the bytes in a line of the symbol
      for (int srcIdx = srcStartIdx; srcIdx <= srcEndIdx; srcIdx++) {
        int oldByte = dst.getByte(dstIdx);
        register = ((register | src.getByte(srcIdx)) << shiftVal2) & 0xffff;

        int newByte = (register >> 8) & 0xff;
        dst.setByte(dstIdx++, combineBytes(oldByte, newByte, op));

        register <<= shiftVal1;
        register &= 0xffff;

        if (srcIdx == srcEndIdx) {
          newByte = (register >> (8 - shiftVal2)) & 0xff;

          if (padding != 0) {
            newByte = unpad(8 + toShift, newByte);
          }

          oldByte = dst.getByte(dstIdx);
          dst.setByte(dstIdx, combineBytes(oldByte, newByte, op));
        }
      }
    }
  }

  /// Computes unpad.
  static int unpad(int padding, int value) => ((value >> padding) << padding) & 0xff;
}
