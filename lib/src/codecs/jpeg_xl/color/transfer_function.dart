import 'dart:math' as math;

import 'package:imcodec/src/codecs/jpeg_xl/color/color_encoding.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';

/// A transfer function: conversions between encoded and linear light.
abstract final class TransferFunction {
  /// Creates a transfer function.
  const TransferFunction();

  /// Converts an encoded sample to linear light.
  double toLinear(double input);

  /// Converts a linear-light sample to encoded light.
  double fromLinear(double linear);

  /// Returns the implementation for a transfer-function identifier.
  static TransferFunction forTransfer(int transferIdentifier) {
    switch (transferIdentifier) {
      case ColorEncodingConstants.linearTransferFunction:
        return const _Linear();
      case ColorEncodingConstants.srgbTransferFunction:
        return const _Srgb();
      case ColorEncodingConstants.pqTransferFunction:
        return const _Pq();
      case ColorEncodingConstants.bt709TransferFunction:
        return const _Bt709();
      case ColorEncodingConstants.dciTransferFunction:
        return const GammaTransferFunction(gammaTimesTenMillion: 3846154);
    }
    if (transferIdentifier < 1 << 24) {
      return GammaTransferFunction(gammaTimesTenMillion: transferIdentifier);
    }
    throw JpegXlUnsupportedException(feature: 'transfer-function-$transferIdentifier');
  }
}

/// Implements the identity transfer function for linear samples.
final class _Linear extends TransferFunction {
  /// Creates the stateless linear transfer function.
  const _Linear();
  @override
  double toLinear(double input) => input;
  @override
  double fromLinear(double linear) => linear;
}

/// Implements the standard sRGB electro-optical transfer function.
final class _Srgb extends TransferFunction {
  /// Creates the stateless sRGB transfer function.
  const _Srgb();
  @override
  double toLinear(double input) => input < 0.0404482362771082 ? input * 0.07739938080495357 : math.pow((input + 0.055) * 0.9478672985781991, 2.4).toDouble();
  @override
  double fromLinear(double linear) => linear < 0.00313066844250063 ? linear * 12.92 : 1.055 * math.pow(linear, 0.4166666666666667) - 0.055;
}

/// Implements the BT.709 transfer function.
final class _Bt709 extends TransferFunction {
  /// Creates the stateless BT.709 transfer function.
  const _Bt709();
  @override
  double toLinear(double input) =>
      input < 0.081242858298635133011 ? input * 0.22222222222222222222 : math.pow((input + 0.0992968268094429403) * 0.90967241568627260377, 2.2222222222222222222).toDouble();
  @override
  double fromLinear(double linear) => linear < 0.018053968510807807336 ? 4.5 * linear : 1.0992968268094429403 * math.pow(linear, 0.45) - 0.0992968268094429403;
}

/// Implements the perceptual-quantizer transfer function.
final class _Pq extends TransferFunction {
  /// Creates the stateless perceptual-quantizer transfer function.
  const _Pq();
  @override
  double toLinear(double input) {
    final double poweredSample = math.pow(input, 0.012683313515655965121).toDouble();
    return math.pow((poweredSample - 0.8359375) / (18.8515625 + 18.6875 * poweredSample), 6.2725880551301684533).toDouble();
  }

  @override
  double fromLinear(double linear) {
    final double poweredSample = math.pow(linear, 0.159423828125).toDouble();
    return math.pow((0.8359375 + 18.8515625 * poweredSample) / (1 + 18.6875 * poweredSample), 78.84375).toDouble();
  }
}

/// Represents gamma transfer function.
final class GammaTransferFunction extends TransferFunction {
  /// Gamma multiplied by ten million, as stored in the bitstream.
  final int gammaTimesTenMillion;

  /// Creates a gamma transfer function.
  const GammaTransferFunction({
    required this.gammaTimesTenMillion,
  });

  /// Gamma exponent applied by the transfer function.
  double get _gamma => gammaTimesTenMillion * 1e-7;

  @override
  double toLinear(double input) => input <= 0 ? 0 : math.pow(input, 1.0 / _gamma).toDouble();

  @override
  double fromLinear(double linear) => linear <= 0 ? 0 : math.pow(linear, _gamma).toDouble();
}
