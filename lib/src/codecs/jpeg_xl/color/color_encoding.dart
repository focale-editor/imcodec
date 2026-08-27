import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Color-related enum constants from the JPEG XL spec. Kept as plain ints
/// (mirroring jxlatte's ColorEncodingConstants) so bitstream values map directly.
abstract final class ColorEncodingConstants {
  /// Specification constant identifying color space XYB.
  static const colorSpaceXyb = 2;

  /// Specification constant identifying custom primaries.
  static const customPrimaries = 2;

  /// Specification constant identifying BT 2100 primaries.
  static const bt2100Primaries = 9;

  /// Specification constant identifying p 3 primaries.
  static const p3Primaries = 11;

  /// Specification constant identifying d 50 white point.
  static const d50WhitePoint = -1;

  /// Specification constant identifying d 65 white point.
  static const d65WhitePoint = 1;

  /// Specification constant identifying custom white point.
  static const customWhitePoint = 2;

  /// Specification constant identifying e white point.
  static const eWhitePoint = 10;

  /// Specification constant identifying dci white point.
  static const dciWhitePoint = 11;

  /// Specification constant identifying color space RGB.
  static const colorSpaceRgb = 0;

  /// Specification constant identifying color space gray.
  static const colorSpaceGray = 1;

  /// Specification constant identifying sRGB primaries.
  static const srgbPrimaries = 1;

  /// Specification constant identifying color space unknown.
  static const colorSpaceUnknown = 3;

  /// Specification constant identifying perceptual rendering intent.
  static const perceptualRenderingIntent = 0;

  /// Specification constant identifying relative rendering intent.
  static const relativeRenderingIntent = 1;

  /// Specification constant identifying saturation rendering intent.
  static const saturationRenderingIntent = 2;

  /// Specification constant identifying absolute rendering intent.
  static const absoluteRenderingIntent = 3;

  /// Transfer-function identifier for BT.709.
  static const int bt709TransferFunction = 1 + (1 << 24);

  /// Transfer-function identifier for an unspecified function.
  static const int unknownTransferFunction = 2 + (1 << 24);

  /// Transfer-function identifier for linear-light samples.
  static const int linearTransferFunction = 8 + (1 << 24);

  /// Transfer-function identifier for sRGB.
  static const int srgbTransferFunction = 13 + (1 << 24);

  /// Transfer-function identifier for hybrid log-gamma.
  static const int hlgTransferFunction = 18 + (1 << 24);

  /// Transfer-function identifier for Digital Cinema Initiatives gamma.
  static const int dciTransferFunction = 17 + (1 << 24);

  /// Transfer-function identifier for the perceptual quantizer.
  static const int pqTransferFunction = 16 + (1 << 24);

  /// Whether [primaries] identifies a supported set of color primaries.
  static bool validatePrimaries(int primaries) => primaries == srgbPrimaries || primaries == customPrimaries || primaries == bt2100Primaries || primaries == p3Primaries;

  /// Whether [whitePoint] identifies a supported white point.
  static bool validateWhitePoint(int whitePoint) => whitePoint == d65WhitePoint || whitePoint == customWhitePoint || whitePoint == eWhitePoint || whitePoint == dciWhitePoint;

  /// Whether [colorEncoding] identifies a supported color space.
  static bool validateColorSpace(int colorEncoding) => colorEncoding >= 0 && colorEncoding <= 3;

  /// Whether [renderingIntent] identifies a valid ICC rendering intent.
  static bool validateRenderingIntent(int renderingIntent) => renderingIntent >= 0 && renderingIntent <= 3;

  /// Whether [transfer] identifies a supported transfer function or gamma.
  static bool validateTransferFunction(int transfer) {
    if (transfer < 0) {
      return false;
    }
    if (transfer <= 10000000) {
      return true;
    }
    if (transfer < 1 << 24) {
      return false;
    }
    return transfer == bt709TransferFunction ||
        transfer == unknownTransferFunction ||
        transfer == linearTransferFunction ||
        transfer == srgbTransferFunction ||
        transfer == pqTransferFunction ||
        transfer == dciTransferFunction ||
        transfer == hlgTransferFunction;
  }

  /// Returns a human-readable name for [primaries].
  static String describePrimaries(int primaries) => switch (primaries) {
    srgbPrimaries => 'sRGB / BT.709',
    bt2100Primaries => 'BT Rec.2100 / BT Rec.2020',
    p3Primaries => 'P3',
    _ => 'Unknown',
  };

  /// Returns a human-readable name for [whitePoint].
  static String describeWhitePoint(int whitePoint) => switch (whitePoint) {
    d65WhitePoint => 'D65',
    eWhitePoint => 'Standard Illuminant E',
    dciWhitePoint => 'DCI',
    d50WhitePoint => 'D50',
    _ => 'Unknown',
  };

  /// Returns a human-readable name for [transfer].
  static String describeTransferFunction(int transfer) {
    if (transfer < 1 << 24) {
      return 'Gamma ${transfer * 1e-7}';
    }
    return switch (transfer) {
      bt709TransferFunction => 'BT.709',
      linearTransferFunction => 'Linear',
      srgbTransferFunction => 'sRGB',
      pqTransferFunction => 'PQ',
      dciTransferFunction => 'DCI',
      hlgTransferFunction => 'HLG',
      _ => 'Unknown',
    };
  }

  /// Returns the CIE xy coordinates selected by [whitePoint].
  static CieXy? whitePointCoordinates(int whitePoint) => switch (whitePoint) {
    d65WhitePoint => const CieXy(x: 0.3127, y: 0.3290),
    eWhitePoint => const CieXy(x: 1 / 3, y: 1 / 3),
    dciWhitePoint => const CieXy(x: 0.314, y: 0.351),
    d50WhitePoint => const CieXy(x: 0.34567, y: 0.34567),
    _ => null,
  };

  /// Returns the CIE xy primaries selected by [primaries].
  static CiePrimaries? primariesCoordinates(int primaries) => switch (primaries) {
    srgbPrimaries => const CiePrimaries(red: CieXy(x: 0.639998686, y: 0.330010138), green: CieXy(x: 0.300003784, y: 0.600003357), blue: CieXy(x: 0.150002046, y: 0.059997204)),
    bt2100Primaries => const CiePrimaries(red: CieXy(x: 0.708, y: 0.292), green: CieXy(x: 0.170, y: 0.797), blue: CieXy(x: 0.131, y: 0.046)),
    p3Primaries => const CiePrimaries(red: CieXy(x: 0.680, y: 0.320), green: CieXy(x: 0.265, y: 0.690), blue: CieXy(x: 0.150, y: 0.060)),
    _ => null,
  };
}

/// A CIE xy chromaticity coordinate.
final class CieXy {
  /// Horizontal coordinate.
  final double x;

  /// Vertical coordinate.
  final double y;

  /// Creates a CIE xy.
  const CieXy({
    required this.x,
    required this.y,
  });

  /// Reads custom.
  factory CieXy.readCustom({
    required BitReader reader,
  }) {
    final int ux = reader.readU32(0, 19, 524288, 19, 1048576, 20, 2097152, 21);
    final int uy = reader.readU32(0, 19, 524288, 19, 1048576, 20, 2097152, 21);
    return CieXy(x: unpackSigned(ux) * 1e-6, y: unpackSigned(uy) * 1e-6);
  }

  /// Whether the supplied value matches this entry.
  bool matches(CieXy other) => (x - other.x).abs() + (y - other.y).abs() < 1e-4;

  @override
  String toString() => 'CieXy($x, $y)';
}

/// Red/green/blue CIE xy primaries.
final class CiePrimaries {
  /// CIE xy coordinates of the red primary.
  final CieXy red;

  /// CIE xy coordinates of the green primary.
  final CieXy green;

  /// CIE xy coordinates of the blue primary.
  final CieXy blue;

  /// Creates a CIE primaries.
  const CiePrimaries({
    required this.red,
    required this.green,
    required this.blue,
  });

  /// Whether the supplied value matches this entry.
  bool matches(CiePrimaries other) => red.matches(other.red) && green.matches(other.green) && blue.matches(other.blue);
}

/// Represents tone mapping.
final class ToneMapping {
  /// Target display luminance in candela per square metre.
  final double intensityTarget;

  /// Minimum nits.
  final double minNits;

  /// Whether the tone mapping enables relative to max display.
  final bool relativeToMaxDisplay;

  /// Fraction below which tone mapping remains linear.
  final double linearBelow;

  /// Creates a tone mapping.
  const ToneMapping() : intensityTarget = 255, minNits = 0, relativeToMaxDisplay = false, linearBelow = 0;

  /// Reads this structure from the bitstream.
  factory ToneMapping.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return const ToneMapping();
    }
    final double intensityTarget = reader.readF16();
    if (intensityTarget <= 0) {
      throw const JpegXlInvalidBitstreamException(message: 'intensity target must be positive');
    }
    final double minNits = reader.readF16();
    if (minNits < 0 || minNits > intensityTarget) {
      throw const JpegXlInvalidBitstreamException(message: 'min nits must be in [0, intensityTarget]');
    }
    final bool relativeToMaxDisplay = reader.readBool();
    final double linearBelow = reader.readF16();
    if (relativeToMaxDisplay && (linearBelow < 0 || linearBelow > 1)) {
      throw const JpegXlInvalidBitstreamException(message: 'linear below out of relative range');
    }
    if (!relativeToMaxDisplay && linearBelow < 0) {
      throw const JpegXlInvalidBitstreamException(message: 'linear below must be nonnegative');
    }
    return ToneMapping._(intensityTarget: intensityTarget, minNits: minNits, relativeToMaxDisplay: relativeToMaxDisplay, linearBelow: linearBelow);
  }

  /// Creates a tone mapping.
  const ToneMapping._({
    required this.intensityTarget,
    required this.minNits,
    required this.relativeToMaxDisplay,
    required this.linearBelow,
  });
}

/// The `ColourEncoding` header bundle.
final class ColorEncodingBundle {
  /// Whether the image uses an embedded ICC profile.
  final bool useIccProfile;

  /// Color-space identifier declared by the codestream.
  final int colorEncoding;

  /// White-point identifier declared by the codestream.
  final int whitePoint;

  /// Decoded CIE xy coordinates of the white point.
  final CieXy white;

  /// Color-primary identifier declared by the codestream.
  final int primaries;

  /// Decoded red, green, and blue primary coordinates.
  final CiePrimaries prim;

  /// Transfer function applied to encoded color samples.
  final int transferFunction;

  /// ICC rendering-intent identifier declared by the codestream.
  final int renderingIntent;

  /// Creates a color encoding bundle.
  const ColorEncodingBundle()
    : useIccProfile = false,
      colorEncoding = ColorEncodingConstants.colorSpaceRgb,
      whitePoint = ColorEncodingConstants.d65WhitePoint,
      white = const CieXy(x: 0.3127, y: 0.3290),
      primaries = ColorEncodingConstants.srgbPrimaries,
      prim = const CiePrimaries(red: CieXy(x: 0.639998686, y: 0.330010138), green: CieXy(x: 0.300003784, y: 0.600003357), blue: CieXy(x: 0.150002046, y: 0.059997204)),
      transferFunction = ColorEncodingConstants.srgbTransferFunction,
      renderingIntent = ColorEncodingConstants.relativeRenderingIntent;

  /// Reads this structure from the bitstream.
  factory ColorEncodingBundle.read({
    required BitReader reader,
  }) {
    final bool allDefault = reader.readBool();
    final bool useIccProfile = !allDefault && reader.readBool();
    final int colorEncoding = allDefault ? ColorEncodingConstants.colorSpaceRgb : reader.readEnum();
    if (!ColorEncodingConstants.validateColorSpace(colorEncoding)) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid ColorSpace enum');
    }
    final int whitePoint;
    if (!allDefault && !useIccProfile && colorEncoding != ColorEncodingConstants.colorSpaceXyb) {
      whitePoint = reader.readEnum();
    } else {
      whitePoint = ColorEncodingConstants.d65WhitePoint;
    }
    if (!ColorEncodingConstants.validateWhitePoint(whitePoint)) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid WhitePoint enum');
    }
    final CieXy white = whitePoint == ColorEncodingConstants.customWhitePoint ? CieXy.readCustom(reader: reader) : ColorEncodingConstants.whitePointCoordinates(whitePoint)!;
    final int primaries;
    if (!allDefault && !useIccProfile && colorEncoding != ColorEncodingConstants.colorSpaceXyb && colorEncoding != ColorEncodingConstants.colorSpaceGray) {
      primaries = reader.readEnum();
    } else {
      primaries = ColorEncodingConstants.srgbPrimaries;
    }
    if (!ColorEncodingConstants.validatePrimaries(primaries)) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid Primaries enum');
    }
    final CiePrimaries prim;
    if (primaries == ColorEncodingConstants.customPrimaries) {
      final red = CieXy.readCustom(reader: reader);
      final green = CieXy.readCustom(reader: reader);
      final blue = CieXy.readCustom(reader: reader);
      prim = CiePrimaries(red: red, green: green, blue: blue);
    } else {
      prim = ColorEncodingConstants.primariesCoordinates(primaries)!;
    }
    int transferFunction = ColorEncodingConstants.srgbTransferFunction;
    int renderingIntent = ColorEncodingConstants.relativeRenderingIntent;
    if (!allDefault && !useIccProfile) {
      final bool useGamma = reader.readBool();
      transferFunction = useGamma ? reader.readBits(24) : (1 << 24) + reader.readEnum();
      if (!ColorEncodingConstants.validateTransferFunction(transferFunction)) {
        throw const JpegXlInvalidBitstreamException(message: 'illegal transfer function');
      }
      renderingIntent = reader.readEnum();
      if (!ColorEncodingConstants.validateRenderingIntent(renderingIntent)) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid RenderingIntent enum');
      }
    }
    return ColorEncodingBundle._(
      useIccProfile: useIccProfile,
      colorEncoding: colorEncoding,
      whitePoint: whitePoint,
      white: white,
      primaries: primaries,
      prim: prim,
      transferFunction: transferFunction,
      renderingIntent: renderingIntent,
    );
  }

  /// Creates a color encoding bundle.
  const ColorEncodingBundle._({
    required this.useIccProfile,
    required this.colorEncoding,
    required this.whitePoint,
    required this.white,
    required this.primaries,
    required this.prim,
    required this.transferFunction,
    required this.renderingIntent,
  });
}
