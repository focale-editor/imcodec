part of '../jbig2.dart';

/// An immutable monochrome page with one most-significant-bit-first bit per pixel.
final class Jbig2Bitmap {
  /// Page width, excluding padding bits at the end of each row.
  final int width;

  /// Number of packed rows.
  final int height;

  /// Bytes per row, equal to `(width + 7) ~/ 8`.
  final int rowStride;

  /// Whether a set bit represents black; PDF samples normally use false.
  final bool oneIsBlack;

  /// Read-only packed rows; unused bits at the right edge represent white.
  final Uint8List bytes;

  /// Owns normalized output independently of the decoder's internal buffers.
  const Jbig2Bitmap._({required this.width, required this.height, required this.rowStride, required this.oneIsBlack, required this.bytes});

  /// Copies compact output while normalizing polarity and row padding.
  factory Jbig2Bitmap._fromDecoded(_Jbig2Bitmap source, {required bool oneIsBlack}) {
    final Uint8List bytes = Uint8List.fromList(source.bitmap);
    if (!oneIsBlack) {
      for (int index = 0; index < bytes.length; index++) {
        bytes[index] ^= 255;
      }
    }
    final int used = source.width % 8;
    if (used != 0) {
      final int padding = (1 << (8 - used)) - 1;
      for (int row = 0; row < source.height; row++) {
        final int last = (row + 1) * source.rowStride - 1;
        bytes[last] = oneIsBlack ? bytes[last] & ~padding : bytes[last] | padding;
      }
    }
    return Jbig2Bitmap._(width: source.width, height: source.height, rowStride: source.rowStride, oneIsBlack: oneIsBlack, bytes: bytes.asUnmodifiableView());
  }
}
