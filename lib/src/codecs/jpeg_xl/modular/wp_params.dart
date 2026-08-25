import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Self-correcting (weighted) predictor parameters, from the modular stream
/// header.
final class WpParams {
  /// Stores the param1 value used while processing JPEG XL data.
  ///
  final int param1;

  /// Stores the param2 value used while processing JPEG XL data.
  ///
  final int param2;

  /// Stores the param3a value used while processing JPEG XL data.
  ///
  final int param3a;

  /// Stores the param3b value used while processing JPEG XL data.
  ///
  final int param3b;

  /// Stores the param3c value used while processing JPEG XL data.
  ///
  final int param3c;

  /// Stores the param3d value used while processing JPEG XL data.
  ///
  final int param3d;

  /// Stores the param3e value used while processing JPEG XL data.
  ///
  final int param3e;

  /// Stores the weight value used while processing JPEG XL data.
  ///
  final List<int> weight;

  /// Processes read information in a JPEG XL codestream.
  ///
  factory WpParams.read({
    required BitReader reader,
  }) {
    if (reader.readBool()) {
      return const WpParams._(
        param1: 16,
        param2: 10,
        param3a: 7,
        param3b: 7,
        param3c: 7,
        param3d: 0,
        param3e: 0,
        weight: [13, 12, 12, 12],
      );
    }
    final int param1 = reader.readBits(5);
    final int param2 = reader.readBits(5);
    final int param3a = reader.readBits(5);
    final int param3b = reader.readBits(5);
    final int param3c = reader.readBits(5);
    final int param3d = reader.readBits(5);
    final int param3e = reader.readBits(5);
    final weight = List<int>.generate(4, (_) => reader.readBits(4));
    return WpParams._(param1: param1, param2: param2, param3a: param3a, param3b: param3b, param3c: param3c, param3d: param3d, param3e: param3e, weight: weight);
  }

  /// Creates Wp params state for JPEG XL processing.
  ///
  const WpParams._({
    required this.param1,
    required this.param2,
    required this.param3a,
    required this.param3b,
    required this.param3c,
    required this.param3d,
    required this.param3e,
    required this.weight,
  });
}
