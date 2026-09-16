import 'dart:typed_data';

import 'package:imcodec/src/codecs/exception.dart';

/// Place value of the high word, kept out of JavaScript's 32-bit shifts.
const int _wordRange = 0x100000000;

/// Largest file offset representable exactly by JavaScript integers.
const int _maximumExactOffset = 0x1fffffffffffff;

/// Reads two little-endian words and bounds them before combining them.
///
/// [maxOffset] is the last permitted position in the input byte buffer.
/// Comparing words first rejects oversized offsets without rounding them or
/// discarding the high word in a JavaScript bitwise operation.
int readOffset(ByteData data, int offset, {required int maxOffset}) {
  final int low = data.getUint32(offset, Endian.little);
  final int high = data.getUint32(offset + 4, Endian.little);
  final int maximumHigh = maxOffset ~/ _wordRange;
  if (maxOffset < 0 || high > maximumHigh || (high == maximumHigh && low > maxOffset % _wordRange) || high > 0x1fffff) {
    throw const ImageCodecException('OpenEXR block offset lies outside the file');
  }
  return high * _wordRange + low;
}

/// Writes a file offset as two little-endian words on the Web.
void writeOffset(ByteData data, int offset, int value) {
  if (value < 0 || value > _maximumExactOffset) {
    throw RangeError.range(value, 0, _maximumExactOffset, 'value');
  }
  data
    ..setUint32(offset, value % _wordRange, Endian.little)
    ..setUint32(offset + 4, value ~/ _wordRange, Endian.little);
}
