part of '../jbig2.dart';

/// Encodes RGBA images as arithmetic-coded, lossless JBIG2 generic regions.
///
/// Opaque binary pixels are required unless [Jbig2EncodeOptions.threshold]
/// explicitly requests conversion to black and white.
final class Jbig2Encoder extends RasterEncoder<Jbig2EncodeOptions> {
  /// Creates an encoder with strict binary input by default.
  const Jbig2Encoder({Jbig2EncodeOptions defaultOptions = const Jbig2EncodeOptions()}) : super(defaultEncodeOptions: defaultOptions);

  @override
  Uint8List encodeWithOptions(Image input, Jbig2EncodeOptions options) => _encode(input, options, embedded: false);

  /// Encodes a PDF JBIG2Decode stream without a file header or global segments.
  Uint8List encodeEmbedded(Image input, {Jbig2EncodeOptions? encodeOptions}) => _encode(input, encodeOptions ?? defaultEncodeOptions, embedded: true);

  /// Converts the source and writes one page with an immediate generic region.
  Uint8List _encode(Image input, Jbig2EncodeOptions options, {required bool embedded}) {
    final int? threshold = options.threshold;
    if (threshold != null && (threshold < 0 || threshold > 255)) {
      throw RangeError.range(threshold, 0, 255, 'threshold');
    }
    if (input.width > 0x7fffffff || input.height > 0x7fffffff) {
      throw const ImageCodecException('JBIG2 dimensions exceed signed 32-bit limits');
    }
    final _Jbig2Bitmap bitmap = _Jbig2Bitmap(width: input.width, height: input.height);
    for (int y = 0; y < input.height; y++) {
      for (int x = 0; x < input.width; x++) {
        final int offset = (y * input.width + x) * 4;
        final int red = input.bytes[offset];
        final int green = input.bytes[offset + 1];
        final int blue = input.bytes[offset + 2];
        final int alpha = input.bytes[offset + 3];
        if (threshold == null) {
          if (alpha != 255 || red != green || red != blue || (red != 0 && red != 255)) {
            throw const ImageCodecException('JBIG2 requires opaque black-and-white pixels; set threshold to convert color or alpha');
          }
          if (red == 0) {
            bitmap.setPixel(x, y, 1);
          }
        } else {
          final int luminance = (299 * red + 587 * green + 114 * blue + 500) ~/ 1000;
          final int composited = (luminance * alpha + 255 * (255 - alpha) + 127) ~/ 255;
          if (composited < threshold) {
            bitmap.setPixel(x, y, 1);
          }
        }
      }
    }
    final OutputBuffer output = OutputBuffer(bigEndian: true);
    if (!embedded) {
      output.writeBytes([0x97, 0x4a, 0x42, 0x32, 0x0d, 0x0a, 0x1a, 0x0a]);
      output.writeByte(1);
      output.writeUint32(1);
    }
    final OutputBuffer page = OutputBuffer(bigEndian: true)
      ..writeUint32(input.width)
      ..writeUint32(input.height)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeByte(1)
      ..writeUint16(0);
    _writeSegment(output, number: 1, type: 48, page: 1, data: page.takeBytes());
    final Uint8List compressed = _Jbig2GenericRegionEncoder(bitmap: bitmap, typicalPrediction: options.typicalPrediction).encode();
    final OutputBuffer region = OutputBuffer(bigEndian: true)
      ..writeUint32(input.width)
      ..writeUint32(input.height)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeByte(0)
      ..writeByte(options.typicalPrediction ? 8 : 0)
      ..writeBytes([3, 255, 253, 255, 2, 254, 254, 254])
      ..writeBytes(compressed);
    _writeSegment(output, number: 2, type: 39, page: 1, data: region.takeBytes());
    _writeSegment(output, number: 3, type: 49, page: 1, data: Uint8List(0));
    if (!embedded) {
      _writeSegment(output, number: 4, type: 51, page: 0, data: Uint8List(0));
    }
    return output.takeBytes();
  }

  /// Writes a short segment header with no references and its payload.
  void _writeSegment(OutputBuffer output, {required int number, required int type, required int page, required Uint8List data}) {
    output
      ..writeUint32(number)
      ..writeByte(type)
      ..writeByte(0)
      ..writeByte(page)
      ..writeUint32(data.length)
      ..writeBytes(data);
  }
}

/// Controls explicit binarization and arithmetic row prediction.
final class Jbig2EncodeOptions extends RasterEncodeOptions {
  /// Luminance cutoff, or null to require already opaque binary input.
  ///
  /// When set, RGB is converted using integer BT.601 luminance, alpha is
  /// composited over white, and values strictly below the cutoff become black.
  final int? threshold;

  /// Compresses repeated rows using JBIG2 typical prediction.
  final bool typicalPrediction;

  /// Creates options that preserve binary pixels exactly.
  const Jbig2EncodeOptions({this.threshold, this.typicalPrediction = true});
}
