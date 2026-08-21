/// Marker bytes used by the baseline JPEG encoder.
abstract final class JpegMarker {
  /// Start of frame, baseline discrete cosine transform.
  static const int sof0 = 0xc0;

  /// Define Huffman tables.
  static const int dht = 0xc4;

  /// Start of image.
  static const int soi = 0xd8;

  /// End of image.
  static const int eoi = 0xd9;

  /// Start of scan.
  static const int sos = 0xda;

  /// Define quantization tables.
  static const int dqt = 0xdb;

  /// JFIF application marker.
  static const int app0 = 0xe0;
}
