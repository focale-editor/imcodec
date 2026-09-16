import 'dart:typed_data';

import 'package:imcodec/src/codecs/exception.dart';

/// Reads a little-endian file offset using the native 64-bit accessor.
int readOffset(ByteData data, int offset, {required int maxOffset}) {
  final int value = data.getUint64(offset, Endian.little);
  if (value < 0 || value > maxOffset) {
    throw const ImageCodecException('OpenEXR block offset lies outside the file');
  }
  return value;
}

/// Writes a little-endian file offset using the native 64-bit accessor.
void writeOffset(ByteData data, int offset, int value) => data.setUint64(offset, value, Endian.little);
