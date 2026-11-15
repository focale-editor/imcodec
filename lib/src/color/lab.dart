import 'dart:math' as math;

/// Converts ICC-encoded Lab samples, between 0 and 1 as
/// [DecodedColorModel.lab] stores them, to encoded sRGB between 0 and 1.
///
/// Lab is relative to D50; sRGB is reached through XYZ with Bradford
/// adaptation to D65, as ICC profiles do. Colours outside sRGB are clipped.
(double, double, double) labToSrgb(double lightness, double a, double b) {
  final double l = lightness * 100;
  final double fy = (l + 16) / 116;
  final double fx = fy + (a * 255 - 128) / 500;
  final double fz = fy - (b * 255 - 128) / 200;
  final double x = 0.96422 * _inverse(fx);
  final double y = _inverse(fy);
  final double z = 0.82521 * _inverse(fz);
  return (
    _encode(3.1338561 * x - 1.6168667 * y - 0.4906146 * z),
    _encode(-0.9787684 * x + 1.9161415 * y + 0.0334540 * z),
    _encode(0.0719453 * x - 0.2289914 * y + 1.4052427 * z),
  );
}

/// Inverse of the CIE Lab companding function.
double _inverse(double value) => value > 6 / 29 ? value * value * value : 3 * (6 / 29) * (6 / 29) * (value - 4 / 29);

/// Encodes linear sRGB with its transfer curve, clipped to 0 through 1.
double _encode(double linear) {
  final double value = linear.isFinite ? linear.clamp(0.0, 1.0) : 0;
  return value <= 0.0031308 ? value * 12.92 : 1.055 * math.pow(value, 1 / 2.4) - 0.055;
}
