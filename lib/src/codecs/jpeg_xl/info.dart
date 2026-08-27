import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/extra_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/container.dart';

/// Exposes JPEG XL metadata without decoding pixel data.
final class JpegXlCodestreamInfo {
  /// Parsed image metadata backing the exposed properties.
  final ImageHeader _header;

  /// Whether the file used the ISOBMFF container format.
  final bool isContainer;

  /// Parses metadata from a bare codestream or container without decoding pixels.
  factory JpegXlCodestreamInfo.fromBytes({required Uint8List bytes}) {
    final DemuxedStream demuxed = demuxContainer(bytes);
    final BitReader reader = BitReader(data: demuxed.codestream);
    final ImageHeader header = ImageHeader.read(reader: reader, level: demuxed.level);
    return JpegXlCodestreamInfo._(header: header, isContainer: demuxed.isContainer);
  }

  /// Creates parsed metadata from a decoded header.
  JpegXlCodestreamInfo._({required this._header, required this.isContainer});

  /// Wraps an already parsed streaming header.
  JpegXlCodestreamInfo.internal({required this._header, required this.isContainer});

  /// Output width after orientation (the size callers should allocate).
  int get width => _header.orientedSize.width;

  /// Output height after orientation.
  int get height => _header.orientedSize.height;

  /// Width as stored in the codestream, before orientation is applied.
  int get encodedWidth => _header.size.width;

  /// Height as stored in the codestream, before orientation is applied.
  int get encodedHeight => _header.size.height;

  /// Number of significant bits in each color sample.
  int get bitsPerSample => _header.bitDepth.bitsPerSample;

  /// Whether color samples use a floating-point representation.
  bool get usesFloatSamples => _header.bitDepth.usesFloatSamples;

  /// Number of exponent bits used by floating-point samples.
  int get exponentBits => _header.bitDepth.exponentBits;

  /// Exif-style orientation already applied to [width] and [height].
  int get orientation => _header.orientation;

  /// Whether the image has one grayscale color channel.
  bool get isGrayscale => _header.isGrayscale;

  /// Whether the image carries an alpha channel.
  bool get hasAlpha => _header.hasAlpha;

  /// Whether alpha is associated with premultiplied color samples.
  bool get alphaPremultiplied => _header.alphaIndices.isNotEmpty && _header.extraChannels[_header.alphaIndices.first].alphaAssociated;

  /// Number of non-color channels stored by the image.
  int get extraChannelCount => _header.extraChannels.length;

  /// Whether the codestream contains animation timing metadata.
  bool get isAnimated => _header.isAnimated;

  /// Whether the color channels are XYB-encoded (true implies lossy).
  bool get isXybEncoded => _header.xybEncoded;

  /// Whether color interpretation relies on an embedded ICC profile.
  bool get usesIccProfile => _header.colorEncoding.useIccProfile;

  /// Conformance level (5 or 10).
  int get level => _header.level;

  /// Target display intensity in candela per square metre.
  double get intensityTarget => _header.toneMapping.intensityTarget;

  /// Returns a human-readable summary of the declared color encoding.
  String get colorDescription {
    final ColorEncodingBundle colorEncoding = _header.colorEncoding;
    if (colorEncoding.useIccProfile) {
      return 'ICC profile';
    }
    final String colorSpace = switch (colorEncoding.colorEncoding) {
      ColorEncodingConstants.colorSpaceGray => 'Grayscale',
      ColorEncodingConstants.colorSpaceRgb => 'RGB',
      ColorEncodingConstants.colorSpaceXyb => 'XYB',
      _ => 'Unknown',
    };
    return '$colorSpace, ${ColorEncodingConstants.describeWhitePoint(colorEncoding.whitePoint)}, '
        '${ColorEncodingConstants.describePrimaries(colorEncoding.primaries)} primaries, '
        '${ColorEncodingConstants.describeTransferFunction(colorEncoding.transferFunction)} transfer';
  }

  /// Returns display descriptions for all extra channels.
  List<String> get extraChannelDescriptions => [
    for (final ExtraChannelInfo extraChannel in _header.extraChannels)
      if (extraChannel.name.isNotEmpty) '${ExtraChannelType.toDisplayString(extraChannel.type)} (${extraChannel.name})' else ExtraChannelType.toDisplayString(extraChannel.type),
  ];

  /// The parsed header, for internal decoder use.
  ImageHeader get header => _header;

  @override
  String toString() =>
      'JpegXlCodestreamInfo(${width}x$height, $bitsPerSample-bit, '
      '${isGrayscale ? 'grayscale' : 'RGB'}'
      '${hasAlpha ? '+alpha' : ''}'
      '${isAnimated ? ', animated' : ''})';
}
