part of '../png.dart';

/// Computes the CRC-32 checksum used by PNG chunks.
abstract final class _PngChecksum {
  /// Lookup table for the PNG CRC-32 polynomial.
  static final List<int> _table = List<int>.generate(256, _tableValue, growable: false);

  /// Computes a checksum over a four-byte chunk [type] and its [data].
  static int compute(List<int> type, Uint8List data) {
    int checksum = 0xffffffff;
    for (final int byte in type.followedBy(data)) {
      checksum = _table[(checksum ^ byte) & 0xff] ^ (checksum >>> 8);
    }
    return (checksum ^ 0xffffffff) & 0xffffffff;
  }

  /// Produces one entry of the CRC-32 lookup table.
  static int _tableValue(int index) {
    int value = index;
    for (int bit = 0; bit < 8; bit++) {
      value = value.isOdd ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    return value;
  }
}
