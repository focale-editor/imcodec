import 'dart:convert';

import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/bit_depth.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Extra channel type constants (spec values).
abstract final class ExtraChannelType {
  /// Stores the alpha value used while processing JPEG XL data.
  ///
  static const alpha = 0;

  /// Stores the depth value used while processing JPEG XL data.
  ///
  static const depth = 1;

  /// Stores the spot color value used while processing JPEG XL data.
  ///
  static const spotColor = 2;

  /// Stores the selection mask value used while processing JPEG XL data.
  ///
  static const selectionMask = 3;

  /// Stores the cmyk black value used while processing JPEG XL data.
  ///
  static const cmykBlack = 4;

  /// Stores the color filter array value used while processing JPEG XL data.
  ///
  static const colorFilterArray = 5;

  /// Stores the thermal value used while processing JPEG XL data.
  ///
  static const thermal = 6;

  /// Stores the non optional value used while processing JPEG XL data.
  ///
  static const nonOptional = 15;

  /// Stores the optional value used while processing JPEG XL data.
  ///
  static const optional = 16;

  /// Processes validate information in a JPEG XL codestream.
  ///
  static bool validate(int ec) => ec >= 0 && ec <= 6 || ec == 15 || ec == 16;

  /// Processes to display string information in a JPEG XL codestream.
  ///
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
  /// Stores the type value used while processing JPEG XL data.
  ///
  final int type;

  /// Stores the bit depth value used while processing JPEG XL data.
  ///
  final BitDepthHeader bitDepth;

  /// Stores the dim shift value used while processing JPEG XL data.
  ///
  final int dimShift;

  /// Stores the name value used while processing JPEG XL data.
  ///
  final String name;

  /// Stores the alpha associated value used while processing JPEG XL data.
  ///
  final bool alphaAssociated;

  /// Stores the red value used while processing JPEG XL data.
  ///
  final double red;

  /// Stores the green value used while processing JPEG XL data.
  ///
  final double green;

  /// Stores the blue value used while processing JPEG XL data.
  ///
  final double blue;

  /// Stores the solidity value used while processing JPEG XL data.
  ///
  final double solidity;

  /// Stores the cfa index value used while processing JPEG XL data.
  ///
  final int cfaIndex;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory ExtraChannelInfo.read({
    required BitReader reader,
  }) {
    final bool dAlpha = reader.readBool();
    final int type;
    final BitDepthHeader bitDepth;
    final int dimShift;
    final String name;
    final bool alphaAssociated;
    if (!dAlpha) {
      type = reader.readEnum();
      if (!ExtraChannelType.validate(type)) {
        throw const JpegXlInvalidBitstreamException(message: 'illegal extra channel type');
      }
      bitDepth = BitDepthHeader.read(reader: reader);
      dimShift = reader.readU32(0, 0, 3, 0, 4, 0, 1, 3);
      final int nameLen = reader.readU32(0, 0, 0, 4, 16, 5, 48, 10);
      // No byte-alignment guarantee, so read the UTF-8 name bytewise.
      final nameBuffer = List<int>.generate(nameLen, (_) => reader.readBits(8));
      name = utf8.decode(nameBuffer, allowMalformed: true);
      alphaAssociated = type == ExtraChannelType.alpha && reader.readBool();
    } else {
      type = ExtraChannelType.alpha;
      bitDepth = const BitDepthHeader();
      dimShift = 0;
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
      dimShift: dimShift,
      name: name,
      alphaAssociated: alphaAssociated,
      red: red,
      green: green,
      blue: blue,
      solidity: solidity,
      cfaIndex: cfaIndex,
    );
  }

  /// Creates Extra channel info state for JPEG XL processing.
  ///
  const ExtraChannelInfo._({
    required this.type,
    required this.bitDepth,
    required this.dimShift,
    required this.name,
    required this.alphaAssociated,
    required this.red,
    required this.green,
    required this.blue,
    required this.solidity,
    required this.cfaIndex,
  });
}
