part of '../png.dart';

/// Computes the CRC-32 checksum used by PNG chunks.
abstract final class _PngChecksum {
  /// Computes a checksum over a four-byte chunk [type] and its [data].
  static int compute(List<int> type, Uint8List data) =>
      (Crc32Accumulator()
            ..add(type)
            ..add(data))
          .value;
}
