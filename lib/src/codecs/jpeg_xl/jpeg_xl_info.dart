import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/extra_channel.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/container.dart';

/// Header-level information about a JPEG XL image, parsed without decoding
/// any pixels. Cheap: reads only the first few hundred bytes.
final class JpegXlCodestreamInfo {
  /// Parsed image metadata backing the exposed properties.
  final ImageHeader _header;

  /// Whether the file used the ISOBMFF container format.
  final bool isContainer;

  /// Parses metadata from a bare codestream or container without decoding pixels.
  factory JpegXlCodestreamInfo.fromBytes({required Uint8List bytes}) {
    final DemuxedStream demuxed = demuxContainer(bytes);
    final reader = BitReader(data: demuxed.codestream);
    final header = ImageHeader.read(reader: reader, level: demuxed.level);
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
  int get exponentBits => _header.bitDepth.expBits;

  /// EXIF-style orientation (1–8) already applied to [width]/[height].
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

  /// Human-readable color encoding summary.
  String get colorDescription {
    final ColorEncodingBundle ce = _header.colorEncoding;
    if (ce.useIccProfile) {
      return 'ICC profile';
    }
    final String space = switch (ce.colorEncoding) {
      ColorFlags.ceGray => 'Grayscale',
      ColorFlags.ceRgb => 'RGB',
      ColorFlags.ceXyb => 'XYB',
      _ => 'Unknown',
    };
    return '$space, ${ColorFlags.whitePointToString(ce.whitePoint)}, '
        '${ColorFlags.primariesToString(ce.primaries)} primaries, '
        '${ColorFlags.transferToString(ce.tf)} transfer';
  }

  /// Names/types of extra channels, e.g. `['Alpha']`.
  List<String> get extraChannelDescriptions => [
    for (final ec in _header.extraChannels)
      if (ec.name.isNotEmpty) '${ExtraChannelType.toDisplayString(ec.type)} (${ec.name})' else ExtraChannelType.toDisplayString(ec.type),
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
