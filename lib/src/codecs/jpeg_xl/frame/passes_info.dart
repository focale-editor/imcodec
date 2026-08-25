import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// The `Passes` bundle from the frame header.
final class PassesInfo {
  /// Stores the num passes value used while processing JPEG XL data.
  ///
  final int numPasses;

  /// Stores the num dS value used while processing JPEG XL data.
  ///
  final int numDS;

  /// Stores the shift value used while processing JPEG XL data.
  ///
  final List<int> shift;

  /// Stores the down sample value used while processing JPEG XL data.
  ///
  final List<int> downSample;

  /// Stores the last pass value used while processing JPEG XL data.
  ///
  final List<int> lastPass;

  /// Processes defaults information in a JPEG XL codestream.
  ///
  PassesInfo.defaults() : numPasses = 1, numDS = 0, shift = const [0], downSample = const [1], lastPass = const [0];

  /// Processes read information in a JPEG XL codestream.
  ///
  factory PassesInfo.read({
    required BitReader reader,
  }) {
    final int numPasses = reader.readU32(1, 0, 2, 0, 3, 0, 4, 3);
    final int numDS = numPasses != 1 ? reader.readU32(0, 0, 1, 0, 2, 0, 3, 1) : 0;
    if (numDS >= numPasses) {
      throw const JpegXlInvalidBitstreamException(message: 'num_ds < num_passes violated');
    }
    final shift = List<int>.filled(numPasses, 0);
    for (var i = 0; i < numPasses - 1; i++) {
      shift[i] = reader.readBits(2);
    }
    final downSample = List<int>.filled(numDS + 1, 1);
    for (var i = 0; i < numDS; i++) {
      downSample[i] = 1 << reader.readBits(2);
    }
    final lastPass = List<int>.filled(numDS + 1, numPasses - 1);
    for (var i = 0; i < numDS; i++) {
      lastPass[i] = reader.readU32(0, 0, 1, 0, 2, 0, 0, 3);
    }
    return PassesInfo._(numPasses: numPasses, numDS: numDS, shift: shift, downSample: downSample, lastPass: lastPass);
  }

  /// Creates Passes info state for JPEG XL processing.
  ///
  PassesInfo._({
    required this.numPasses,
    required this.numDS,
    required this.shift,
    required this.downSample,
    required this.lastPass,
  });
}
