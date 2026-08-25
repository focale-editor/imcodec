import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Color-related enum constants from the JPEG XL spec. Kept as plain ints
/// (mirroring jxlatte's ColorFlags) so bitstream values map directly.
abstract final class ColorFlags {
  /// Stores the ce xyb value used while processing JPEG XL data.
  ///
  static const ceXyb = 2;

  /// Stores the pri custom value used while processing JPEG XL data.
  ///
  static const priCustom = 2;

  /// Stores the pri bt2100 value used while processing JPEG XL data.
  ///
  static const priBt2100 = 9;

  /// Stores the pri p3 value used while processing JPEG XL data.
  ///
  static const priP3 = 11;

  /// Stores the wp d50 value used while processing JPEG XL data.
  ///
  static const wpD50 = -1;

  /// Stores the wp d65 value used while processing JPEG XL data.
  ///
  static const wpD65 = 1;

  /// Stores the wp custom value used while processing JPEG XL data.
  ///
  static const wpCustom = 2;

  /// Stores the wp e value used while processing JPEG XL data.
  ///
  static const wpE = 10;

  /// Stores the wp dci value used while processing JPEG XL data.
  ///
  static const wpDci = 11;

  /// Stores the ce rgb value used while processing JPEG XL data.
  ///
  static const ceRgb = 0;

  /// Stores the ce gray value used while processing JPEG XL data.
  ///
  static const ceGray = 1;

  /// Stores the pri srgb value used while processing JPEG XL data.
  ///
  static const priSrgb = 1;

  /// Stores the ce unknown value used while processing JPEG XL data.
  ///
  static const ceUnknown = 3;

  /// Stores the ri perceptual value used while processing JPEG XL data.
  ///
  static const riPerceptual = 0;

  /// Stores the ri relative value used while processing JPEG XL data.
  ///
  static const riRelative = 1;

  /// Stores the ri saturation value used while processing JPEG XL data.
  ///
  static const riSaturation = 2;

  /// Stores the ri absolute value used while processing JPEG XL data.
  ///
  static const riAbsolute = 3;

  /// Processes tf bt709 information in a JPEG XL codestream.
  ///
  static const int tfBt709 = 1 + (1 << 24);

  /// Processes tf unknown information in a JPEG XL codestream.
  ///
  static const int tfUnknown = 2 + (1 << 24);

  /// Processes tf linear information in a JPEG XL codestream.
  ///
  static const int tfLinear = 8 + (1 << 24);

  /// Processes tf srgb information in a JPEG XL codestream.
  ///
  static const int tfSrgb = 13 + (1 << 24);

  /// Processes tf hlg information in a JPEG XL codestream.
  ///
  static const int tfHlg = 18 + (1 << 24);

  /// Processes tf dci information in a JPEG XL codestream.
  ///
  static const int tfDci = 17 + (1 << 24);

  /// Processes tf pq information in a JPEG XL codestream.
  ///
  static const int tfPq = 16 + (1 << 24);

  /// Processes validate primaries information in a JPEG XL codestream.
  ///
  static bool validatePrimaries(int primaries) => primaries == priSrgb || primaries == priCustom || primaries == priBt2100 || primaries == priP3;

  /// Processes validate white point information in a JPEG XL codestream.
  ///
  static bool validateWhitePoint(int whitePoint) => whitePoint == wpD65 || whitePoint == wpCustom || whitePoint == wpE || whitePoint == wpDci;

  /// Processes validate color encoding information in a JPEG XL codestream.
  ///
  static bool validateColorEncoding(int colorEncoding) => colorEncoding >= 0 && colorEncoding <= 3;

  /// Processes validate rendering intent information in a JPEG XL codestream.
  ///
  static bool validateRenderingIntent(int renderingIntent) => renderingIntent >= 0 && renderingIntent <= 3;

  /// Processes validate transfer information in a JPEG XL codestream.
  ///
  static bool validateTransfer(int transfer) {
    if (transfer < 0) {
      return false;
    }
    if (transfer <= 10000000) {
      return true;
    }
    if (transfer < 1 << 24) {
      return false;
    }
    return transfer == tfBt709 || transfer == tfUnknown || transfer == tfLinear || transfer == tfSrgb || transfer == tfPq || transfer == tfDci || transfer == tfHlg;
  }

  /// Processes primaries to string information in a JPEG XL codestream.
  ///
  static String primariesToString(int primaries) => switch (primaries) {
    priSrgb => 'sRGB / BT.709',
    priBt2100 => 'BT Rec.2100 / BT Rec.2020',
    priP3 => 'P3',
    _ => 'Unknown',
  };

  /// Processes white point to string information in a JPEG XL codestream.
  ///
  static String whitePointToString(int whitePoint) => switch (whitePoint) {
    wpD65 => 'D65',
    wpE => 'Standard Illuminant E',
    wpDci => 'DCI',
    wpD50 => 'D50',
    _ => 'Unknown',
  };

  /// Processes transfer to string information in a JPEG XL codestream.
  ///
  static String transferToString(int transfer) {
    if (transfer < 1 << 24) {
      return 'Gamma ${transfer * 1e-7}';
    }
    return switch (transfer) {
      tfBt709 => 'BT.709',
      tfLinear => 'Linear',
      tfSrgb => 'sRGB',
      tfPq => 'PQ',
      tfDci => 'DCI',
      tfHlg => 'HLG',
      _ => 'Unknown',
    };
  }

  /// Processes get white point information in a JPEG XL codestream.
  ///
  static CieXy? getWhitePoint(int whitePoint) => switch (whitePoint) {
    wpD65 => const CieXy(x: 0.3127, y: 0.3290),
    wpE => const CieXy(x: 1 / 3, y: 1 / 3),
    wpDci => const CieXy(x: 0.314, y: 0.351),
    wpD50 => const CieXy(x: 0.34567, y: 0.34567),
    _ => null,
  };

  /// Processes get primaries information in a JPEG XL codestream.
  ///
  static CiePrimaries? getPrimaries(int primaries) => switch (primaries) {
    priSrgb => const CiePrimaries(red: CieXy(x: 0.639998686, y: 0.330010138), green: CieXy(x: 0.300003784, y: 0.600003357), blue: CieXy(x: 0.150002046, y: 0.059997204)),
    priBt2100 => const CiePrimaries(red: CieXy(x: 0.708, y: 0.292), green: CieXy(x: 0.170, y: 0.797), blue: CieXy(x: 0.131, y: 0.046)),
    priP3 => const CiePrimaries(red: CieXy(x: 0.680, y: 0.320), green: CieXy(x: 0.265, y: 0.690), blue: CieXy(x: 0.150, y: 0.060)),
    _ => null,
  };
}

/// A CIE xy chromaticity coordinate.
final class CieXy {
  /// Stores the x value used while processing JPEG XL data.
  ///
  final double x;

  /// Stores the y value used while processing JPEG XL data.
  ///
  final double y;

  /// Creates Cie xy data for JPEG XL processing.
  ///
  const CieXy({
    required this.x,
    required this.y,
  });

  /// Processes read custom information in a JPEG XL codestream.
  ///
  factory CieXy.readCustom({
    required BitReader reader,
  }) {
    final int ux = reader.readU32(0, 19, 524288, 19, 1048576, 20, 2097152, 21);
    final int uy = reader.readU32(0, 19, 524288, 19, 1048576, 20, 2097152, 21);
    return CieXy(x: unpackSigned(ux) * 1e-6, y: unpackSigned(uy) * 1e-6);
  }

  /// Processes matches information in a JPEG XL codestream.
  ///
  bool matches(CieXy other) => (x - other.x).abs() + (y - other.y).abs() < 1e-4;

  @override
  String toString() => 'CieXy($x, $y)';
}

/// Red/green/blue CIE xy primaries.
final class CiePrimaries {
  /// Stores the red value used while processing JPEG XL data.
  ///
  final CieXy red;

  /// Stores the green value used while processing JPEG XL data.
  ///
  final CieXy green;

  /// Stores the blue value used while processing JPEG XL data.
  ///
  final CieXy blue;

  /// Creates Cie primaries data for JPEG XL processing.
  ///
  const CiePrimaries({
    required this.red,
    required this.green,
    required this.blue,
  });

  /// Processes matches information in a JPEG XL codestream.
  ///
  bool matches(CiePrimaries other) => red.matches(other.red) && green.matches(other.green) && blue.matches(other.blue);
}

/// Represents Tone mapping data used while processing JPEG XL images.
///
final class ToneMapping {
  /// Stores the intensity target value used while processing JPEG XL data.
  ///
  final double intensityTarget;

  /// Stores the min nits value used while processing JPEG XL data.
  ///
  final double minNits;

  /// Stores the relative to max display value used while processing JPEG XL data.
  ///
  final bool relativeToMaxDisplay;

  /// Stores the linear below value used while processing JPEG XL data.
  ///
  final double linearBelow;

  /// Creates Tone mapping data for JPEG XL processing.
  ///
  const ToneMapping() : intensityTarget = 255, minNits = 0, relativeToMaxDisplay = false, linearBelow = 0;

  /// Processes read information in a JPEG XL codestream.
  ///
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

  /// Creates Tone mapping state for JPEG XL processing.
  ///
  const ToneMapping._({
    required this.intensityTarget,
    required this.minNits,
    required this.relativeToMaxDisplay,
    required this.linearBelow,
  });
}

/// The `ColourEncoding` header bundle.
final class ColorEncodingBundle {
  /// Stores the use icc profile value used while processing JPEG XL data.
  ///
  final bool useIccProfile;

  /// Stores the color encoding value used while processing JPEG XL data.
  ///
  final int colorEncoding;

  /// Stores the white point value used while processing JPEG XL data.
  ///
  final int whitePoint;

  /// Stores the white value used while processing JPEG XL data.
  ///
  final CieXy white;

  /// Stores the primaries value used while processing JPEG XL data.
  ///
  final int primaries;

  /// Stores the prim value used while processing JPEG XL data.
  ///
  final CiePrimaries prim;

  /// Stores the tf value used while processing JPEG XL data.
  ///
  final int tf;

  /// Stores the rendering intent value used while processing JPEG XL data.
  ///
  final int renderingIntent;

  /// Creates Color encoding bundle data for JPEG XL processing.
  ///
  const ColorEncodingBundle()
    : useIccProfile = false,
      colorEncoding = ColorFlags.ceRgb,
      whitePoint = ColorFlags.wpD65,
      white = const CieXy(x: 0.3127, y: 0.3290),
      primaries = ColorFlags.priSrgb,
      prim = const CiePrimaries(red: CieXy(x: 0.639998686, y: 0.330010138), green: CieXy(x: 0.300003784, y: 0.600003357), blue: CieXy(x: 0.150002046, y: 0.059997204)),
      tf = ColorFlags.tfSrgb,
      renderingIntent = ColorFlags.riRelative;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory ColorEncodingBundle.read({
    required BitReader reader,
  }) {
    final bool allDefault = reader.readBool();
    final bool useIccProfile = !allDefault && reader.readBool();
    final int colorEncoding = allDefault ? ColorFlags.ceRgb : reader.readEnum();
    if (!ColorFlags.validateColorEncoding(colorEncoding)) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid ColorSpace enum');
    }
    final int whitePoint;
    if (!allDefault && !useIccProfile && colorEncoding != ColorFlags.ceXyb) {
      whitePoint = reader.readEnum();
    } else {
      whitePoint = ColorFlags.wpD65;
    }
    if (!ColorFlags.validateWhitePoint(whitePoint)) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid WhitePoint enum');
    }
    final CieXy white = whitePoint == ColorFlags.wpCustom ? CieXy.readCustom(reader: reader) : ColorFlags.getWhitePoint(whitePoint)!;
    final int primaries;
    if (!allDefault && !useIccProfile && colorEncoding != ColorFlags.ceXyb && colorEncoding != ColorFlags.ceGray) {
      primaries = reader.readEnum();
    } else {
      primaries = ColorFlags.priSrgb;
    }
    if (!ColorFlags.validatePrimaries(primaries)) {
      throw const JpegXlInvalidBitstreamException(message: 'invalid Primaries enum');
    }
    final CiePrimaries prim;
    if (primaries == ColorFlags.priCustom) {
      final red = CieXy.readCustom(reader: reader);
      final green = CieXy.readCustom(reader: reader);
      final blue = CieXy.readCustom(reader: reader);
      prim = CiePrimaries(red: red, green: green, blue: blue);
    } else {
      prim = ColorFlags.getPrimaries(primaries)!;
    }
    int tf = ColorFlags.tfSrgb;
    int renderingIntent = ColorFlags.riRelative;
    if (!allDefault && !useIccProfile) {
      final bool useGamma = reader.readBool();
      tf = useGamma ? reader.readBits(24) : (1 << 24) + reader.readEnum();
      if (!ColorFlags.validateTransfer(tf)) {
        throw const JpegXlInvalidBitstreamException(message: 'illegal transfer function');
      }
      renderingIntent = reader.readEnum();
      if (!ColorFlags.validateRenderingIntent(renderingIntent)) {
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
      tf: tf,
      renderingIntent: renderingIntent,
    );
  }

  /// Creates Color encoding bundle state for JPEG XL processing.
  ///
  const ColorEncodingBundle._({
    required this.useIccProfile,
    required this.colorEncoding,
    required this.whitePoint,
    required this.white,
    required this.primaries,
    required this.prim,
    required this.tf,
    required this.renderingIntent,
  });
}
