part of '../webp.dart';

/// Identifies the compressed pixel representation discovered by a decoder.
enum _WebPFormat {
  /// Format has not been identified.
  undefined,

  /// Lossy VP8 data.
  lossy,

  /// Lossless VP8L data.
  lossless,
}

/// Shares dimensions and alpha data between WebP decoding stages.
final class _WebPDecodingInfo {
  /// Image width in pixels.
  int width = 0;

  /// Image height in pixels.
  int height = 0;

  /// Whether decoded pixels can contain alpha.
  bool hasAlpha = false;

  /// Pixel representation selected from the bitstream.
  _WebPFormat format = _WebPFormat.undefined;

  /// Optional compressed alpha data paired with lossy VP8.
  _WebPBuffer? alphaData;

  /// Length of [alphaData].
  int alphaSize = 0;

  /// Creates empty decoding information.
  _WebPDecodingInfo();
}
