part of '../open_exr.dart';

/// Decodes RGB, RGBA, or luminance OpenEXR scan-line parts.
///
/// Half, float, and unsigned-integer channels are returned as floating-point
/// RGBA. Scene-linear colour is converted from the authored chromaticities to
/// encoded sRGB so the result has an explicit interpretation in consumers that
/// use [DecodedImage]. Extra arbitrary channels are skipped without allocation.
final class OpenExrDecoder extends RasterDecoder<OpenExrDecodeOptions> {
  /// Creates an OpenEXR decoder.
  const OpenExrDecoder();

  @override
  Image decodeImage(Uint8List bytes, OpenExrDecodeOptions options) => decodeData(
    bytes,
    maxPixels: options.maxPixels,
    maxDecodedBytes: options.maxPixels * 16,
  ).toImage();

  /// Decodes authored colour channels without reducing HDR precision.
  DecodedImage decodeData(
    Uint8List bytes, {
    required int maxPixels,
    required int maxDecodedBytes,
  }) {
    if (maxPixels < 1) {
      throw RangeError.range(maxPixels, 1, null, 'maxPixels');
    }
    if (maxDecodedBytes < 1) {
      throw RangeError.range(maxDecodedBytes, 1, null, 'maxDecodedBytes');
    }
    final _OpenExrHeader header = _OpenExrHeader.parse(bytes);
    final int pixelCount = header.width * header.height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException(
        'Decoded OpenEXR contains $pixelCount pixels, exceeding the '
        '$maxPixels pixel limit',
      );
    }
    final int outputByteLength = pixelCount * 16;
    if (outputByteLength > maxDecodedBytes) {
      throw ImageCodecException(
        'Decoded OpenEXR needs $outputByteLength bytes, exceeding the '
        '$maxDecodedBytes byte limit',
      );
    }
    final int maximumExpandedBlockLength = math.min(header.linesPerBlock, header.height) * header.bytesPerScanLine;
    if (maximumExpandedBlockLength > maxDecodedBytes) {
      throw ImageCodecException(
        'An expanded OpenEXR block needs $maximumExpandedBlockLength bytes, '
        'exceeding the $maxDecodedBytes byte limit',
      );
    }

    final _OpenExrColourChannels colour = header.colourChannels;
    final Float32List straight = Float32List(pixelCount * 4);
    for (int pixel = 0; pixel < pixelCount; pixel++) {
      straight[pixel * 4 + 3] = 1;
    }
    final int blockCount = (header.height + header.linesPerBlock - 1) ~/ header.linesPerBlock;
    final _OpenExrReader offsetReader = _OpenExrReader(
      bytes,
      offset: header.offsetTableOffset,
    );
    final List<int> blockOffsets = [
      for (int block = 0; block < blockCount; block++) offsetReader.uint64(),
    ];
    final Uint8List visitedRows = Uint8List(header.height);
    for (final int blockOffset in blockOffsets) {
      final _OpenExrReader blockReader = _OpenExrReader(
        bytes,
        offset: blockOffset,
      );
      final int blockY = blockReader.int32();
      final int packedLength = blockReader.uint32();
      final int firstRow = blockY - header.minimumY;
      if (firstRow < 0 || firstRow >= header.height) {
        throw const ImageCodecException(
          'An OpenEXR scan-line block starts outside its data window',
        );
      }
      final int rowCount = math.min(
        header.linesPerBlock,
        header.height - firstRow,
      );
      final int expectedLength = rowCount * header.bytesPerScanLine;
      final Uint8List packed = blockReader.bytes(packedLength);
      final Uint8List unpacked = _unpackBlock(
        packed,
        expectedLength: expectedLength,
        compression: header.compression,
      );
      _decodeBlock(
        unpacked,
        header: header,
        colour: colour,
        firstRow: firstRow,
        rowCount: rowCount,
        output: straight,
        visitedRows: visitedRows,
      );
    }
    if (visitedRows.any((value) => value == 0)) {
      throw const ImageCodecException(
        'OpenEXR scan-line blocks do not cover the complete data window',
      );
    }
    _convertToSrgb(straight, header.chromaticities);
    return DecodedImage(
      width: header.width,
      height: header.height,
      colorModel: DecodedColorModel.rgb,
      sampleFormat: DecodedSampleFormat.float32,
      bytes: straight.buffer.asUint8List(),
      copy: false,
    );
  }

  /// Expands one compressed block to its exact planar byte length.
  Uint8List _unpackBlock(
    Uint8List packed, {
    required int expectedLength,
    required int compression,
  }) {
    if (packed.lengthInBytes == expectedLength) {
      return Uint8List.fromList(packed);
    }
    final Uint8List predicted = switch (compression) {
      1 => _decodeRunLength(packed, expectedLength),
      2 || 3 => _decodeZlib(packed, expectedLength),
      _ => throw ImageCodecException(
        'OpenEXR compression method $compression is not supported',
      ),
    };
    if (predicted.lengthInBytes != expectedLength) {
      throw ImageCodecException(
        'OpenEXR block expands to ${predicted.lengthInBytes} bytes instead '
        'of $expectedLength',
      );
    }
    for (int index = 1; index < predicted.lengthInBytes; index++) {
      predicted[index] = (predicted[index - 1] + predicted[index] - 128) & 0xff;
    }
    final Uint8List output = Uint8List(expectedLength);
    final int evenCount = (expectedLength + 1) ~/ 2;
    for (int index = 0; index < expectedLength; index++) {
      output[index] = index.isEven ? predicted[index ~/ 2] : predicted[evenCount + index ~/ 2];
    }
    return output;
  }

  /// Decompresses one bounded ZIP or ZIPS payload.
  Uint8List _decodeZlib(Uint8List packed, int expectedLength) {
    try {
      return Uint8List.fromList(
        ZlibCodec(maxOutputBytes: expectedLength).decode(packed),
      );
    } on Object catch (error) {
      throw ImageCodecException(
        'Could not decompress the OpenEXR ZIP block',
        cause: error,
      );
    }
  }

  /// Expands the PackBits-like byte stream used by OpenEXR RLE blocks.
  Uint8List _decodeRunLength(Uint8List packed, int expectedLength) {
    final Uint8List output = Uint8List(expectedLength);
    int source = 0;
    int destination = 0;
    while (source < packed.lengthInBytes && destination < expectedLength) {
      final int controlByte = packed[source++];
      final int control = controlByte >= 128 ? controlByte - 256 : controlByte;
      if (control < 0) {
        final int count = -control;
        if (source > packed.lengthInBytes - count || destination > expectedLength - count) {
          throw const ImageCodecException('OpenEXR RLE literal exceeds its block');
        }
        output.setRange(destination, destination + count, packed, source);
        source += count;
        destination += count;
      } else {
        final int count = control + 1;
        if (source >= packed.lengthInBytes || destination > expectedLength - count) {
          throw const ImageCodecException('OpenEXR RLE run exceeds its block');
        }
        output.fillRange(destination, destination + count, packed[source++]);
        destination += count;
      }
    }
    if (source != packed.lengthInBytes || destination != expectedLength) {
      throw const ImageCodecException('OpenEXR RLE block has an invalid length');
    }
    return output;
  }

  /// Decodes channel-major scan lines into interleaved colour samples.
  void _decodeBlock(
    Uint8List bytes, {
    required _OpenExrHeader header,
    required _OpenExrColourChannels colour,
    required int firstRow,
    required int rowCount,
    required Float32List output,
    required Uint8List visitedRows,
  }) {
    final ByteData data = ByteData.sublistView(bytes);
    int position = 0;
    for (int row = 0; row < rowCount; row++) {
      final int outputY = firstRow + row;
      if (visitedRows[outputY] != 0) {
        throw const ImageCodecException('OpenEXR scan-line blocks overlap');
      }
      visitedRows[outputY] = 1;
      for (final _OpenExrChannel channel in header.sortedChannels) {
        final int destinationChannel = colour.destinationFor(channel.name);
        for (int x = 0; x < header.width; x++) {
          final double sample = channel.read(data, position);
          position += channel.bytesPerSample;
          if (destinationChannel < 0) {
            continue;
          }
          final int outputOffset = (outputY * header.width + x) * 4;
          if (destinationChannel == 4) {
            output[outputOffset] = sample;
            output[outputOffset + 1] = sample;
            output[outputOffset + 2] = sample;
          } else {
            output[outputOffset + destinationChannel] = sample;
          }
        }
      }
    }
    if (position != bytes.lengthInBytes) {
      throw const ImageCodecException('OpenEXR block contains trailing sample bytes');
    }
  }

  /// Converts scene-linear authored primaries to encoded working sRGB.
  void _convertToSrgb(
    Float32List samples,
    _OpenExrChromaticities chromaticities,
  ) {
    final List<double> matrix = chromaticities.toLinearSrgbMatrix();
    for (int offset = 0; offset < samples.length; offset += 4) {
      final double sourceRed = _finite(samples[offset]);
      final double sourceGreen = _finite(samples[offset + 1]);
      final double sourceBlue = _finite(samples[offset + 2]);
      final double red = matrix[0] * sourceRed + matrix[1] * sourceGreen + matrix[2] * sourceBlue;
      final double green = matrix[3] * sourceRed + matrix[4] * sourceGreen + matrix[5] * sourceBlue;
      final double blue = matrix[6] * sourceRed + matrix[7] * sourceGreen + matrix[8] * sourceBlue;
      samples[offset] = _linearToSrgb(red);
      samples[offset + 1] = _linearToSrgb(green);
      samples[offset + 2] = _linearToSrgb(blue);
      samples[offset + 3] = _finite(samples[offset + 3]).clamp(0, 1).toDouble();
    }
  }

  /// Replaces non-finite external samples before matrix arithmetic.
  double _finite(double value) => value.isFinite ? value : 0;

  /// Applies the extended sRGB transfer function without clipping finite values.
  double _linearToSrgb(double value) {
    final double sign = value < 0 ? -1 : 1;
    final double magnitude = value.abs();
    final double encoded = magnitude <= 0.0031308 ? 12.92 * magnitude : 1.055 * math.pow(magnitude, 1 / 2.4) - 0.055;
    return sign * encoded;
  }

  @override
  OpenExrDecodeOptions createDecodeOptions({
    int maxPixels = RasterDecodeOptions.defaultMaxPixels,
  }) => OpenExrDecodeOptions(maxPixels: maxPixels);
}

/// The OpenEXT decoder options.
final class OpenExrDecodeOptions extends RasterDecodeOptions {
  /// Creates OpenEXR decoder options.
  const OpenExrDecodeOptions({
    super.maxPixels,
  });
}

/// Reads enough OpenEXR metadata to select the exact decoder path.
DecodedImageMetadata inspectOpenExr(Uint8List bytes) {
  final _OpenExrHeader header = _OpenExrHeader.parse(bytes);
  return DecodedImageMetadata(
    width: header.width,
    height: header.height,
    bitsPerChannel: 32,
    colorModel: DecodedColorModel.rgb,
  );
}

/// Parsed attributes needed by the bounded scan-line decoder.
final class _OpenExrHeader {
  /// Inclusive horizontal data-window origin.
  final int minimumX;

  /// Inclusive vertical data-window origin.
  final int minimumY;

  /// Inclusive horizontal data-window end.
  final int maximumX;

  /// Inclusive vertical data-window end.
  final int maximumY;

  /// Compression identifier stored by the container.
  final int compression;

  /// Authored channels in header order.
  final List<_OpenExrChannel> channels;

  /// Authored colour primaries and white point.
  final _OpenExrChromaticities chromaticities;

  /// Byte offset at which the block-offset table begins.
  final int offsetTableOffset;

  /// Creates one validated parsed header.
  _OpenExrHeader({
    required this.minimumX,
    required this.minimumY,
    required this.maximumX,
    required this.maximumY,
    required this.compression,
    required List<_OpenExrChannel> channels,
    required this.chromaticities,
    required this.offsetTableOffset,
  }) : channels = List<_OpenExrChannel>.unmodifiable(channels) {
    if (maximumX < minimumX || maximumY < minimumY) {
      throw const ImageCodecException('OpenEXR has an invalid data window');
    }
    if (![0, 1, 2, 3].contains(compression)) {
      throw ImageCodecException(
        'OpenEXR compression method $compression is not supported',
      );
    }
    if (channels.isEmpty || channels.any((channel) => channel.xSampling != 1 || channel.ySampling != 1)) {
      throw const ImageCodecException(
        'OpenEXR subsampled or missing channels are not supported',
      );
    }
    colourChannels;
  }

  /// Horizontal pixel count in the data window.
  int get width => maximumX - minimumX + 1;

  /// Vertical pixel count in the data window.
  int get height => maximumY - minimumY + 1;

  /// Channels in the lexical order required by scan-line payloads.
  List<_OpenExrChannel> get sortedChannels => [...channels]..sort((first, second) => first.name.compareTo(second.name));

  /// Bytes occupied by all authored channels in one complete scan line.
  int get bytesPerScanLine => width * channels.fold<int>(0, (total, channel) => total + channel.bytesPerSample);

  /// Scan-line count grouped by the selected compression scheme.
  int get linesPerBlock => compression == 3 ? 16 : 1;

  /// RGB, RGBA, or luminance channel set selected from arbitrary channels.
  _OpenExrColourChannels get colourChannels => _OpenExrColourChannels.select(channels);

  /// Parses one bounded version-two, single-part scan-line header.
  factory _OpenExrHeader.parse(Uint8List bytes) {
    final _OpenExrReader reader = _OpenExrReader(bytes);
    if (reader.uint32() != 20000630) {
      throw const ImageCodecException('Invalid OpenEXR signature');
    }
    final int versionField = reader.uint32();
    if ((versionField & 0xff) != 2) {
      throw ImageCodecException(
        'OpenEXR version ${versionField & 0xff} is not supported',
      );
    }
    if ((versionField & 0x1a00) != 0) {
      throw const ImageCodecException(
        'Tiled, deep, or multipart OpenEXR files are not supported',
      );
    }
    List<_OpenExrChannel>? channels;
    int? compression;
    (int, int, int, int)? dataWindow;
    int? lineOrder;
    _OpenExrChromaticities chromaticities = _OpenExrChromaticities.srgb;
    while (true) {
      final String name = reader.cstring(maximumLength: 255);
      if (name.isEmpty) {
        break;
      }
      final String type = reader.cstring(maximumLength: 255);
      final int length = reader.uint32();
      final Uint8List payload = reader.bytes(length);
      switch (name) {
        case 'channels':
          if (type != 'chlist' || channels != null) {
            throw const ImageCodecException('OpenEXR has an invalid channel list');
          }
          channels = _OpenExrChannel.parseList(payload);
        case 'compression':
          if (type != 'compression' || payload.lengthInBytes != 1 || compression != null) {
            throw const ImageCodecException('OpenEXR has an invalid compression attribute');
          }
          compression = payload[0];
        case 'dataWindow':
          if (type != 'box2i' || payload.lengthInBytes != 16 || dataWindow != null) {
            throw const ImageCodecException('OpenEXR has an invalid data window');
          }
          final ByteData box = ByteData.sublistView(payload);
          dataWindow = (
            box.getInt32(0, Endian.little),
            box.getInt32(4, Endian.little),
            box.getInt32(8, Endian.little),
            box.getInt32(12, Endian.little),
          );
        case 'lineOrder':
          if (type != 'lineOrder' || payload.lengthInBytes != 1 || lineOrder != null) {
            throw const ImageCodecException(
              'OpenEXR has an invalid line-order attribute',
            );
          }
          lineOrder = payload[0];
          if (lineOrder != 0) {
            throw const ImageCodecException(
              'Decreasing or random OpenEXR scan-line order is not supported',
            );
          }
        case 'chromaticities':
          if (type != 'chromaticities' || payload.lengthInBytes != 32) {
            throw const ImageCodecException('OpenEXR has invalid chromaticities');
          }
          chromaticities = _OpenExrChromaticities.parse(payload);
      }
    }
    final List<_OpenExrChannel>? resolvedChannels = channels;
    final int? resolvedCompression = compression;
    final (int, int, int, int)? resolvedWindow = dataWindow;
    if (resolvedChannels == null || resolvedCompression == null || resolvedWindow == null || lineOrder == null) {
      throw const ImageCodecException('OpenEXR is missing a required header attribute');
    }
    return _OpenExrHeader(
      minimumX: resolvedWindow.$1,
      minimumY: resolvedWindow.$2,
      maximumX: resolvedWindow.$3,
      maximumY: resolvedWindow.$4,
      compression: resolvedCompression,
      channels: resolvedChannels,
      chromaticities: chromaticities,
      offsetTableOffset: reader.offset,
    );
  }
}

/// One channel descriptor from an OpenEXR channel list.
final class _OpenExrChannel {
  /// Case-sensitive channel name.
  final String name;

  /// Scalar representation: unsigned integer, half, or float.
  final int pixelType;

  /// Horizontal sampling factor.
  final int xSampling;

  /// Vertical sampling factor.
  final int ySampling;

  /// Creates one channel descriptor.
  const _OpenExrChannel({
    required this.name,
    required this.pixelType,
    required this.xSampling,
    required this.ySampling,
  });

  /// Bytes stored by one sample of this channel.
  int get bytesPerSample => switch (pixelType) {
    0 || 2 => 4,
    1 => 2,
    _ => throw ImageCodecException(
      'OpenEXR channel $name has unsupported pixel type $pixelType',
    ),
  };

  /// Reads one sample and normalizes unsigned integer colour values.
  double read(ByteData data, int offset) => switch (pixelType) {
    0 => data.getUint32(offset, Endian.little) / 4294967295,
    1 => _halfToDouble(data.getUint16(offset, Endian.little)),
    2 => data.getFloat32(offset, Endian.little),
    _ => throw ImageCodecException(
      'OpenEXR channel $name has unsupported pixel type $pixelType',
    ),
  };

  /// Parses the terminated sequence of channel descriptors.
  static List<_OpenExrChannel> parseList(Uint8List payload) {
    final _OpenExrReader reader = _OpenExrReader(payload);
    final List<_OpenExrChannel> channels = [];
    final Set<String> names = {};
    while (true) {
      final String name = reader.cstring(maximumLength: 255);
      if (name.isEmpty) {
        break;
      }
      final int pixelType = reader.int32();
      reader.skip(4);
      final int xSampling = reader.int32();
      final int ySampling = reader.int32();
      if (!names.add(name) || channels.length >= 256 || xSampling < 1 || ySampling < 1) {
        throw const ImageCodecException('OpenEXR has an invalid channel list');
      }
      final _OpenExrChannel channel = _OpenExrChannel(
        name: name,
        pixelType: pixelType,
        xSampling: xSampling,
        ySampling: ySampling,
      );
      channel.bytesPerSample;
      channels.add(channel);
    }
    if (reader.offset != payload.lengthInBytes) {
      throw const ImageCodecException('OpenEXR channel list has trailing bytes');
    }
    return channels;
  }
}

/// Maps one coherent authored channel group into RGBA destinations.
final class _OpenExrColourChannels {
  /// Channel names mapped to zero-based RGBA or luminance destination indices.
  final Map<String, int> destinations;

  /// Creates one immutable channel mapping.
  _OpenExrColourChannels(Map<String, int> destinations) : destinations = Map<String, int>.unmodifiable(destinations);

  /// Returns the destination for [name], or `-1` for an ignored channel.
  int destinationFor(String name) => destinations[name] ?? -1;

  /// Selects unprefixed colour first, then the first complete named layer.
  static _OpenExrColourChannels select(List<_OpenExrChannel> channels) {
    final Map<String, Map<String, String>> groups = {};
    for (final _OpenExrChannel channel in channels) {
      final int separator = channel.name.lastIndexOf('.');
      final String prefix = separator < 0 ? '' : channel.name.substring(0, separator);
      final String component = separator < 0 ? channel.name : channel.name.substring(separator + 1);
      if (const {'R', 'G', 'B', 'A', 'Y'}.contains(component)) {
        groups.putIfAbsent(prefix, () => {})[component] = channel.name;
      }
    }
    final List<String> candidates = groups.keys.toList()
      ..sort((first, second) {
        if (first.isEmpty != second.isEmpty) {
          return first.isEmpty ? -1 : 1;
        }
        return first.compareTo(second);
      });
    for (final String prefix in candidates) {
      final Map<String, String> group = groups[prefix]!;
      if (group.containsKey('R') && group.containsKey('G') && group.containsKey('B')) {
        return _OpenExrColourChannels({
          group['R']!: 0,
          group['G']!: 1,
          group['B']!: 2,
          if (group['A'] case final String alpha) alpha: 3,
        });
      }
      if (group['Y'] case final String luminance) {
        return _OpenExrColourChannels({
          luminance: 4,
          if (group['A'] case final String alpha) alpha: 3,
        });
      }
    }
    throw const ImageCodecException(
      'OpenEXR contains no complete RGB or luminance channel group',
    );
  }
}

/// RGB primaries and white point expressed as CIE xy coordinates.
final class _OpenExrChromaticities {
  /// Standard Rec. 709/sRGB chromaticities used when the attribute is absent.
  static const _OpenExrChromaticities srgb = _OpenExrChromaticities(
    redX: 0.64,
    redY: 0.33,
    greenX: 0.30,
    greenY: 0.60,
    blueX: 0.15,
    blueY: 0.06,
    whiteX: 0.3127,
    whiteY: 0.3290,
  );

  /// Red-primary x chromaticity.
  final double redX;

  /// Red-primary y chromaticity.
  final double redY;

  /// Green-primary x chromaticity.
  final double greenX;

  /// Green-primary y chromaticity.
  final double greenY;

  /// Blue-primary x chromaticity.
  final double blueX;

  /// Blue-primary y chromaticity.
  final double blueY;

  /// White-point x chromaticity.
  final double whiteX;

  /// White-point y chromaticity.
  final double whiteY;

  /// Creates one chromaticity set.
  const _OpenExrChromaticities({
    required this.redX,
    required this.redY,
    required this.greenX,
    required this.greenY,
    required this.blueX,
    required this.blueY,
    required this.whiteX,
    required this.whiteY,
  });

  /// Parses eight little-endian floating-point xy coordinates.
  factory _OpenExrChromaticities.parse(Uint8List bytes) {
    final ByteData data = ByteData.sublistView(bytes);
    final _OpenExrChromaticities value = _OpenExrChromaticities(
      redX: data.getFloat32(0, Endian.little),
      redY: data.getFloat32(4, Endian.little),
      greenX: data.getFloat32(8, Endian.little),
      greenY: data.getFloat32(12, Endian.little),
      blueX: data.getFloat32(16, Endian.little),
      blueY: data.getFloat32(20, Endian.little),
      whiteX: data.getFloat32(24, Endian.little),
      whiteY: data.getFloat32(28, Endian.little),
    );
    value.toLinearSrgbMatrix();
    return value;
  }

  /// Builds the colourimetric matrix from authored RGB into linear sRGB.
  List<double> toLinearSrgbMatrix() {
    final List<double> primaryMatrix = [
      redX / redY,
      greenX / greenY,
      blueX / blueY,
      1,
      1,
      1,
      (1 - redX - redY) / redY,
      (1 - greenX - greenY) / greenY,
      (1 - blueX - blueY) / blueY,
    ];
    if (primaryMatrix.any((value) => !value.isFinite) || whiteY <= 0) {
      throw const ImageCodecException('OpenEXR chromaticities are not finite');
    }
    final List<double> inversePrimaries = _invert3(primaryMatrix);
    final List<double> sourceWhite = [
      whiteX / whiteY,
      1,
      (1 - whiteX - whiteY) / whiteY,
    ];
    final List<double> scale = _multiplyVector(inversePrimaries, sourceWhite);
    final List<double> sourceToXyz = [
      primaryMatrix[0] * scale[0],
      primaryMatrix[1] * scale[1],
      primaryMatrix[2] * scale[2],
      primaryMatrix[3] * scale[0],
      primaryMatrix[4] * scale[1],
      primaryMatrix[5] * scale[2],
      primaryMatrix[6] * scale[0],
      primaryMatrix[7] * scale[1],
      primaryMatrix[8] * scale[2],
    ];
    final List<double> adapted = _adaptWhite(
      sourceToXyz,
      sourceWhite,
      const [0.950455927, 1, 1.089057751],
    );
    return _multiply3(const [
      3.2404542,
      -1.5371385,
      -0.4985314,
      -0.9692660,
      1.8760108,
      0.0415560,
      0.0556434,
      -0.2040259,
      1.0572252,
    ], adapted);
  }

  /// Applies Bradford chromatic adaptation to one RGB-to-XYZ matrix.
  List<double> _adaptWhite(
    List<double> rgbToXyz,
    List<double> sourceWhite,
    List<double> targetWhite,
  ) {
    const List<double> bradford = [
      0.8951,
      0.2664,
      -0.1614,
      -0.7502,
      1.7135,
      0.0367,
      0.0389,
      -0.0685,
      1.0296,
    ];
    const List<double> inverseBradford = [
      0.9869929,
      -0.1470543,
      0.1599627,
      0.4323053,
      0.5183603,
      0.0492912,
      -0.0085287,
      0.0400428,
      0.9684867,
    ];
    final List<double> sourceCone = _multiplyVector(bradford, sourceWhite);
    final List<double> targetCone = _multiplyVector(bradford, targetWhite);
    if (sourceCone.any((value) => !value.isFinite || value.abs() < 1e-12)) {
      throw const ImageCodecException('OpenEXR white point cannot be adapted');
    }
    final List<double> coneScale = [
      targetCone[0] / sourceCone[0],
      targetCone[1] / sourceCone[1],
      targetCone[2] / sourceCone[2],
    ];
    final List<double> diagonalBradford = [
      coneScale[0] * bradford[0],
      coneScale[0] * bradford[1],
      coneScale[0] * bradford[2],
      coneScale[1] * bradford[3],
      coneScale[1] * bradford[4],
      coneScale[1] * bradford[5],
      coneScale[2] * bradford[6],
      coneScale[2] * bradford[7],
      coneScale[2] * bradford[8],
    ];
    return _multiply3(
      _multiply3(inverseBradford, diagonalBradford),
      rgbToXyz,
    );
  }
}

/// Bounded little-endian reader used by OpenEXR headers and blocks.
final class _OpenExrReader {
  /// Complete source bytes.
  final Uint8List _bytes;

  /// Typed primitive view over [_bytes].
  final ByteData _data;

  /// Current byte position.
  int offset;

  /// Creates a reader positioned at [offset].
  _OpenExrReader(Uint8List bytes, {this.offset = 0}) : _bytes = bytes, _data = ByteData.sublistView(bytes) {
    if (offset < 0 || offset > bytes.lengthInBytes) {
      throw const ImageCodecException('OpenEXR offset lies outside the file');
    }
  }

  /// Reads one unsigned byte.
  int uint8() {
    _ensure(1);
    return _bytes[offset++];
  }

  /// Reads one signed little-endian 32-bit integer.
  int int32() {
    _ensure(4);
    final int value = _data.getInt32(offset, Endian.little);
    offset += 4;
    return value;
  }

  /// Reads one unsigned little-endian 32-bit integer.
  int uint32() {
    _ensure(4);
    final int value = _data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  /// Reads one bounded unsigned little-endian 64-bit file offset.
  int uint64() {
    _ensure(8);
    final int value = _data.getUint64(offset, Endian.little);
    offset += 8;
    if (value > _bytes.lengthInBytes - 8) {
      throw const ImageCodecException('OpenEXR block offset lies outside the file');
    }
    return value;
  }

  /// Reads one null-terminated Latin-1 identifier.
  String cstring({required int maximumLength}) {
    final int start = offset;
    while (offset < _bytes.lengthInBytes && _bytes[offset] != 0) {
      if (offset - start >= maximumLength) {
        throw const ImageCodecException('OpenEXR name exceeds its declared limit');
      }
      offset++;
    }
    if (offset >= _bytes.lengthInBytes) {
      throw const ImageCodecException('OpenEXR contains an unterminated name');
    }
    final String value = String.fromCharCodes(_bytes, start, offset);
    offset++;
    return value;
  }

  /// Returns a bounded view over the next [length] bytes.
  Uint8List bytes(int length) {
    if (length < 0) {
      throw const ImageCodecException('OpenEXR declares a negative byte length');
    }
    _ensure(length);
    final Uint8List value = Uint8List.sublistView(
      _bytes,
      offset,
      offset + length,
    );
    offset += length;
    return value;
  }

  /// Advances over [length] bytes after checking bounds.
  void skip(int length) {
    _ensure(length);
    offset += length;
  }

  /// Rejects reads that would pass the end of the source.
  void _ensure(int length) {
    if (length < 0 || offset > _bytes.lengthInBytes - length) {
      throw const ImageCodecException('OpenEXR data is truncated');
    }
  }
}

/// Converts one IEEE-754 binary16 payload to a Dart double.
double _halfToDouble(int bits) {
  final int sign = bits & 0x8000;
  final int exponent = (bits >>> 10) & 0x1f;
  final int fraction = bits & 0x03ff;
  final int floatBits;
  if (exponent == 0) {
    if (fraction == 0) {
      floatBits = sign << 16;
    } else {
      int normalizedFraction = fraction;
      int normalizedExponent = -14;
      while ((normalizedFraction & 0x0400) == 0) {
        normalizedFraction <<= 1;
        normalizedExponent--;
      }
      normalizedFraction &= 0x03ff;
      floatBits = (sign << 16) | ((normalizedExponent + 127) << 23) | (normalizedFraction << 13);
    }
  } else if (exponent == 0x1f) {
    floatBits = (sign << 16) | 0x7f800000 | (fraction << 13);
  } else {
    floatBits = (sign << 16) | ((exponent - 15 + 127) << 23) | (fraction << 13);
  }
  final ByteData data = ByteData(4)..setUint32(0, floatBits, Endian.little);
  return data.getFloat32(0, Endian.little);
}

/// Multiplies two row-major three-by-three matrices.
List<double> _multiply3(List<double> first, List<double> second) => [
  for (int row = 0; row < 3; row++)
    for (int column = 0; column < 3; column++) first[row * 3] * second[column] + first[row * 3 + 1] * second[column + 3] + first[row * 3 + 2] * second[column + 6],
];

/// Multiplies one row-major three-by-three matrix by a vector.
List<double> _multiplyVector(List<double> matrix, List<double> vector) => [
  matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2],
  matrix[3] * vector[0] + matrix[4] * vector[1] + matrix[5] * vector[2],
  matrix[6] * vector[0] + matrix[7] * vector[1] + matrix[8] * vector[2],
];

/// Inverts one finite nonsingular row-major three-by-three matrix.
List<double> _invert3(List<double> matrix) {
  final double determinant =
      matrix[0] * (matrix[4] * matrix[8] - matrix[5] * matrix[7]) - matrix[1] * (matrix[3] * matrix[8] - matrix[5] * matrix[6]) + matrix[2] * (matrix[3] * matrix[7] - matrix[4] * matrix[6]);
  if (!determinant.isFinite || determinant.abs() < 1e-12) {
    throw const ImageCodecException('OpenEXR chromaticities are singular');
  }
  final double inverse = 1 / determinant;
  return [
    (matrix[4] * matrix[8] - matrix[5] * matrix[7]) * inverse,
    (matrix[2] * matrix[7] - matrix[1] * matrix[8]) * inverse,
    (matrix[1] * matrix[5] - matrix[2] * matrix[4]) * inverse,
    (matrix[5] * matrix[6] - matrix[3] * matrix[8]) * inverse,
    (matrix[0] * matrix[8] - matrix[2] * matrix[6]) * inverse,
    (matrix[2] * matrix[3] - matrix[0] * matrix[5]) * inverse,
    (matrix[3] * matrix[7] - matrix[4] * matrix[6]) * inverse,
    (matrix[1] * matrix[6] - matrix[0] * matrix[7]) * inverse,
    (matrix[0] * matrix[4] - matrix[1] * matrix[3]) * inverse,
  ];
}
