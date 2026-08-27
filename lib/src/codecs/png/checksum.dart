part of '../png.dart';

/// Computes the CRC-32 checksum used by PNG chunks.
abstract final class _PngChecksum {
  /// Lookup table for the PNG CRC-32 polynomial.
  static final Uint32List _table = _createTable();

  /// Computes a checksum over a four-byte chunk [type] and its [data].
  static int compute(List<int> type, Uint8List data) {
    final Uint32List table = _table;
    int checksum = 0xffffffff;
    for (int index = 0; index < type.length; index++) {
      checksum = table[(checksum ^ type[index]) & 0xff] ^ (checksum >>> 8);
    }
    for (int index = 0; index < data.length; index++) {
      checksum = table[(checksum ^ data[index]) & 0xff] ^ (checksum >>> 8);
    }
    return (checksum ^ 0xffffffff) & 0xffffffff;
  }

  /// Builds the CRC-32 lookup table.
  static Uint32List _createTable() {
    final Uint32List table = Uint32List(256);
    for (int index = 0; index < table.length; index++) {
      int value = index;
      for (int bit = 0; bit < 8; bit++) {
        value = value.isOdd ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
      }
      table[index] = value;
    }
    return table;
  }
}
