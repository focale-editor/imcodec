part of '../open_exr.dart';

/// Encodes straight RGBA samples as scene-linear half-float OpenEXR.
final class OpenExrEncoder extends RasterEncoder<OpenExrEncodeOptions> {
  /// Creates a half-float OpenEXR encoder.
  const OpenExrEncoder();

  /// Encodes straight eight-bit sRGB pixels.
  @override
  Uint8List encodeImage(Image image, OpenExrEncodeOptions options) => _encode(
    width: image.width,
    height: image.height,
    encodeRows: (firstY, rowCount) => _encodeByteRows(
      image,
      firstY,
      rowCount,
    ),
    compression: options.compression,
  );

  /// Encodes straight extended-sRGB float samples without clipping HDR values.
  static Uint8List encodeFloat32Rgba({
    required int width,
    required int height,
    required Float32List pixels,
    required OpenExrEncodeOptions options,
  }) {
    if (width < 1 || height < 1) {
      throw RangeError('OpenEXR dimensions must be positive');
    }
    final int expectedSamples = width * height * 4;
    if (pixels.length != expectedSamples) {
      throw ImageCodecException(
        'OpenEXR expected $expectedSamples RGBA samples, but received '
        '${pixels.length}',
      );
    }
    return _encode(
      width: width,
      height: height,
      encodeRows: (firstY, rowCount) => _encodeFloatRows(
        pixels,
        width: width,
        firstY: firstY,
        rowCount: rowCount,
      ),
      compression: options.compression,
    );
  }

  /// Builds the header, offset table, and encoded scan-line blocks.
  static Uint8List _encode({
    required int width,
    required int height,
    required Uint8List Function(int firstY, int rowCount) encodeRows,
    required OpenExrCompression compression,
  }) {
    final Uint8List header = _header(width, height, compression);
    final List<Uint8List> blocks = [];
    for (int firstY = 0; firstY < height; firstY += compression.linesPerBlock) {
      final int rowCount = math.min(
        compression.linesPerBlock,
        height - firstY,
      );
      final Uint8List raw = encodeRows(firstY, rowCount);
      final Uint8List packed = _compress(raw, compression);
      final BytesBuilder block = BytesBuilder(copy: false)
        ..add(_int32(firstY))
        ..add(_uint32(packed.lengthInBytes))
        ..add(packed);
      blocks.add(block.takeBytes());
    }
    final int offsetTableLength = blocks.length * 8;
    int blockOffset = header.lengthInBytes + offsetTableLength;
    final BytesBuilder output = BytesBuilder(copy: false)..add(header);
    for (final Uint8List block in blocks) {
      output.add(_uint64(blockOffset));
      blockOffset += block.lengthInBytes;
    }
    blocks.forEach(output.add);
    return output.takeBytes();
  }

  /// Writes the required single-part scan-line header attributes.
  static Uint8List _header(int width, int height, OpenExrCompression compression) {
    final BytesBuilder output = BytesBuilder(copy: false)
      ..add(const [0x76, 0x2f, 0x31, 0x01])
      ..add(_uint32(2))
      ..add(_attribute('channels', 'chlist', _channelList()))
      ..add(_attribute('compression', 'compression', [compression.value]))
      ..add(_attribute('dataWindow', 'box2i', _box(width, height)))
      ..add(_attribute('displayWindow', 'box2i', _box(width, height)))
      ..add(_attribute('lineOrder', 'lineOrder', const [0]))
      ..add(_attribute('pixelAspectRatio', 'float', _float32(1)))
      ..add(_attribute('screenWindowCenter', 'v2f', Uint8List(8)))
      ..add(_attribute('screenWindowWidth', 'float', _float32(1)))
      ..add(
        _attribute(
          'chromaticities',
          'chromaticities',
          _chromaticitiesBytes(_OpenExrChromaticities.srgb),
        ),
      )
      ..addByte(0);
    return output.takeBytes();
  }

  /// Describes alphabetically ordered half-float A, B, G, and R channels.
  static Uint8List _channelList() {
    final BytesBuilder output = BytesBuilder(copy: false);
    for (final String name in const ['A', 'B', 'G', 'R']) {
      output
        ..add(_cstring(name))
        ..add(_int32(1))
        ..add(const [0, 0, 0, 0])
        ..add(_int32(1))
        ..add(_int32(1));
    }
    output.addByte(0);
    return output.takeBytes();
  }

  /// Serializes one zero-origin integer display or data window.
  static Uint8List _box(int width, int height) {
    final BytesBuilder output = BytesBuilder(copy: false)
      ..add(_int32(0))
      ..add(_int32(0))
      ..add(_int32(width - 1))
      ..add(_int32(height - 1));
    return output.takeBytes();
  }

  /// Converts byte rows from encoded sRGB to planar scene-linear half values.
  static Uint8List _encodeByteRows(Image image, int firstY, int rowCount) {
    final ByteData output = ByteData(rowCount * image.width * 8);
    int destination = 0;
    for (int row = 0; row < rowCount; row++) {
      final int sourceRow = (firstY + row) * image.width * 4;
      for (final int channel in const [3, 2, 1, 0]) {
        for (int x = 0; x < image.width; x++) {
          final int byte = image.bytes[sourceRow + x * 4 + channel];
          final double value = channel == 3 ? byte / 255 : _extendedSrgbToLinear(byte / 255);
          output.setUint16(destination, _doubleToHalf(value), Endian.little);
          destination += 2;
        }
      }
    }
    return output.buffer.asUint8List();
  }

  /// Converts float rows from extended sRGB to planar linear half values.
  static Uint8List _encodeFloatRows(
    Float32List pixels, {
    required int width,
    required int firstY,
    required int rowCount,
  }) {
    final ByteData output = ByteData(rowCount * width * 8);
    int destination = 0;
    for (int row = 0; row < rowCount; row++) {
      final int sourceRow = (firstY + row) * width * 4;
      for (final int channel in const [3, 2, 1, 0]) {
        for (int x = 0; x < width; x++) {
          final double sample = pixels[sourceRow + x * 4 + channel];
          if (!sample.isFinite) {
            throw const ImageCodecException(
              'OpenEXR cannot encode non-finite RGBA samples',
            );
          }
          final double value = channel == 3 ? sample.clamp(0, 1).toDouble() : _extendedSrgbToLinear(sample);
          output.setUint16(destination, _doubleToHalf(value), Endian.little);
          destination += 2;
        }
      }
    }
    return output.buffer.asUint8List();
  }

  /// Applies the OpenEXR byte reordering, predictor, and selected compressor.
  static Uint8List _compress(Uint8List source, OpenExrCompression compression) {
    if (compression == OpenExrCompression.none) {
      return source;
    }
    final Uint8List predicted = Uint8List(source.lengthInBytes);
    final int evenCount = (source.lengthInBytes + 1) ~/ 2;
    for (int index = 0; index < source.lengthInBytes; index++) {
      predicted[index.isEven ? index ~/ 2 : evenCount + index ~/ 2] = source[index];
    }
    for (int index = predicted.lengthInBytes - 1; index > 0; index--) {
      predicted[index] = (predicted[index] - predicted[index - 1] + 128) & 0xff;
    }
    final Uint8List compressed = Uint8List.fromList(
      const ZlibCodec().encode(predicted),
    );
    return compressed.lengthInBytes < source.lengthInBytes ? compressed : source;
  }

  /// Converts an extended encoded-sRGB component to scene-linear light.
  static double _extendedSrgbToLinear(double value) {
    final double sign = value < 0 ? -1 : 1;
    final double magnitude = value.abs();
    final double linear = magnitude <= 0.04045 ? magnitude / 12.92 : math.pow((magnitude + 0.055) / 1.055, 2.4).toDouble();
    return sign * linear;
  }

  @override
  OpenExrEncodeOptions createDefaultEncodeOptions() => const OpenExrEncodeOptions();
}

/// Compression methods emitted by [OpenExrEncoder].
enum OpenExrCompression {
  /// Stores one scan line per block without compression.
  none(value: 0, linesPerBlock: 1),

  /// Applies zlib compression independently to every scan line.
  zips(value: 2, linesPerBlock: 1),

  /// Applies zlib compression to groups of up to sixteen scan lines.
  zip(value: 3, linesPerBlock: 16);

  /// Value stored in the OpenEXR `compression` attribute.
  final int value;

  /// Number of consecutive scan lines stored by one encoded block.
  final int linesPerBlock;

  /// Creates one OpenEXR compression choice.
  const OpenExrCompression({
    required this.value,
    required this.linesPerBlock,
  });
}

/// The OpenEXR encode options.
final class OpenExrEncodeOptions extends RasterEncodeOptions {
  /// Compression applied independently to scan-line blocks.
  final OpenExrCompression compression;

  /// Creates OpenEXR encoder options.
  const OpenExrEncodeOptions({
    this.compression = OpenExrCompression.zip,
  });
}

/// Converts a finite Dart double to rounded IEEE-754 binary16 bits.
int _doubleToHalf(double value) {
  final ByteData data = ByteData(4)..setFloat32(0, value, Endian.little);
  final int bits = data.getUint32(0, Endian.little);
  final int sign = (bits >>> 16) & 0x8000;
  final int exponent = (bits >>> 23) & 0xff;
  final int fraction = bits & 0x7fffff;
  if (exponent == 0xff) {
    return sign | (fraction == 0 ? 0x7c00 : 0x7e00);
  }
  final int halfExponent = exponent - 127 + 15;
  if (halfExponent >= 0x1f) {
    return sign | 0x7c00;
  }
  if (halfExponent <= 0) {
    if (halfExponent < -10) {
      return sign;
    }
    final int mantissa = fraction | 0x800000;
    final int shift = 14 - halfExponent;
    final int rounded = (mantissa + (1 << (shift - 1)) - 1 + ((mantissa >>> shift) & 1)) >>> shift;
    return sign | rounded;
  }
  final int roundedFraction = fraction + 0x0fff + ((fraction >>> 13) & 1);
  if ((roundedFraction & 0x800000) != 0) {
    final int roundedExponent = halfExponent + 1;
    return roundedExponent >= 0x1f ? sign | 0x7c00 : sign | (roundedExponent << 10);
  }
  return sign | (halfExponent << 10) | (roundedFraction >>> 13);
}

/// Serializes one OpenEXR header attribute.
Uint8List _attribute(String name, String type, List<int> payload) {
  final BytesBuilder output = BytesBuilder(copy: false)
    ..add(_cstring(name))
    ..add(_cstring(type))
    ..add(_uint32(payload.length))
    ..add(payload);
  return output.takeBytes();
}

/// Serializes one null-terminated ASCII identifier.
Uint8List _cstring(String value) => Uint8List.fromList([
  ...value.codeUnits,
  0,
]);

/// Serializes one signed little-endian 32-bit value.
Uint8List _int32(int value) {
  final ByteData data = ByteData(4)..setInt32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

/// Serializes one unsigned little-endian 32-bit value.
Uint8List _uint32(int value) {
  final ByteData data = ByteData(4)..setUint32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

/// Serializes one unsigned little-endian 64-bit value.
Uint8List _uint64(int value) {
  final ByteData data = ByteData(8)..setUint64(0, value, Endian.little);
  return data.buffer.asUint8List();
}

/// Serializes one little-endian 32-bit floating-point value.
Uint8List _float32(double value) {
  final ByteData data = ByteData(4)..setFloat32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

/// Serializes OpenEXR chromaticities in red, green, blue, white order.
Uint8List _chromaticitiesBytes(_OpenExrChromaticities value) {
  final ByteData data = ByteData(32)
    ..setFloat32(0, value.redX, Endian.little)
    ..setFloat32(4, value.redY, Endian.little)
    ..setFloat32(8, value.greenX, Endian.little)
    ..setFloat32(12, value.greenY, Endian.little)
    ..setFloat32(16, value.blueX, Endian.little)
    ..setFloat32(20, value.blueY, Endian.little)
    ..setFloat32(24, value.whiteX, Endian.little)
    ..setFloat32(28, value.whiteY, Endian.little);
  return data.buffer.asUint8List();
}
