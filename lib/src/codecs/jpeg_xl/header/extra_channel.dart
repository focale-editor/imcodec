import 'dart:convert';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/bit_depth.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Extra channel type constants (spec values).
abstract final class ExtraChannelType {
  /// Specification constant identifying alpha.
  static const alpha = 0;

  /// Specification constant identifying depth.
  static const depth = 1;

  /// Specification constant identifying spot color.
  static const spotColor = 2;

  /// Specification constant identifying selection mask.
  static const selectionMask = 3;

  /// Specification constant identifying cmyk black.
  static const cmykBlack = 4;

  /// Specification constant identifying color filter array.
  static const colorFilterArray = 5;

  /// Specification constant identifying thermal.
  static const thermal = 6;

  /// Specification constant identifying non optional.
  static const nonOptional = 15;

  /// Specification constant identifying optional.
  static const optional = 16;

  /// Validates.
  static bool validate(int ec) => ec >= 0 && ec <= 6 || ec == 15 || ec == 16;

  /// Returns a human-readable description.
  static String toDisplayString(int ec) => switch (ec) {
    alpha => 'Alpha',
    depth => 'Depth',
    spotColor => 'Spot color',
    selectionMask => 'Selection mask',
    cmykBlack => 'CMYK black',
    colorFilterArray => 'CFA',
    thermal => 'Thermal',
    nonOptional => 'Non-optional',
    optional => 'Optional',
    _ => 'Unknown',
  };
}

/// The `ExtraChannelInfo` header bundle.
final class ExtraChannelInfo {
  /// Type identifier defined by the JPEG XL specification.
  final int type;

  /// Sample representation used by the extra channel.
  final BitDepthHeader bitDepth;

  /// Base-two downsampling shift relative to the main image.
  final int dimensionShift;

  /// Name carried by the codestream.
  final String name;

  /// Whether the extra channel enables alpha associated.
  final bool alphaAssociated;

  /// Red component of a spot color.
  final double red;

  /// Green component of a spot color.
  final double green;

  /// Blue component of a spot color.
  final double blue;

  /// Opacity of a spot color.
  final double solidity;

  /// Index of color-filter array in the extra channel.
  final int cfaIndex;

  /// Reads this structure from the bitstream.
  factory ExtraChannelInfo.read({
    required BitReader reader,
  }) {
    final bool dAlpha = reader.readBool();
    final int type;
    final BitDepthHeader bitDepth;
    final int dimensionShift;
    final String name;
    final bool alphaAssociated;
    if (!dAlpha) {
      type = reader.readEnum();
      if (!ExtraChannelType.validate(type)) {
        throw const JpegXlInvalidBitstreamException(message: 'illegal extra channel type');
      }
      bitDepth = BitDepthHeader.read(reader: reader);
      dimensionShift = reader.readU32(0, 0, 3, 0, 4, 0, 1, 3);
      final int nameLen = reader.readU32(0, 0, 0, 4, 16, 5, 48, 10);
      // No byte-alignment guarantee, so read the UTF-8 name bytewise.
      final nameBuffer = List<int>.generate(nameLen, (_) => reader.readBits(8));
      name = utf8.decode(nameBuffer, allowMalformed: true);
      alphaAssociated = type == ExtraChannelType.alpha && reader.readBool();
    } else {
      type = ExtraChannelType.alpha;
      bitDepth = const BitDepthHeader();
      dimensionShift = 0;
      name = '';
      alphaAssociated = false;
    }
    var red = 0.0;
    var green = 0.0;
    var blue = 0.0;
    var solidity = 0.0;
    if (type == ExtraChannelType.spotColor) {
      red = reader.readF16();
      green = reader.readF16();
      blue = reader.readF16();
      solidity = reader.readF16();
    }
    final int cfaIndex = type == ExtraChannelType.colorFilterArray ? reader.readU32(1, 0, 0, 2, 3, 4, 19, 8) : 1;
    return ExtraChannelInfo._(
      type: type,
      bitDepth: bitDepth,
      dimensionShift: dimensionShift,
      name: name,
      alphaAssociated: alphaAssociated,
      red: red,
      green: green,
      blue: blue,
      solidity: solidity,
      cfaIndex: cfaIndex,
    );
  }

  /// Creates an extra channel info.
  const ExtraChannelInfo._({
    required this.type,
    required this.bitDepth,
    required this.dimensionShift,
    required this.name,
    required this.alphaAssociated,
    required this.red,
    required this.green,
    required this.blue,
    required this.solidity,
    required this.cfaIndex,
  });
}
