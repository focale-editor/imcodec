part of '../../webp.dart';

/// Stores the three-byte lossy VP8 frame tag.
final class _Vp8FrameHeader {
  /// Whether the frame is independently decodable.
  bool? isKeyFrame;

  /// VP8 bitstream profile from zero through three.
  int? profile;

  /// Whether the frame is intended for display.
  bool? isVisible;

  /// Byte length of the first compressed partition.
  late int partitionLength;

  /// Creates empty frame-header state.
  _Vp8FrameHeader();
}

/// Stores dimensions and color flags from a lossy VP8 key frame.
final class _Vp8PictureHeader {
  /// Encoded width in pixels.
  int? width;

  /// Encoded height in pixels.
  int? height;

  /// Horizontal scale hint from the frame header.
  int? horizontalScale;

  /// Vertical scale hint from the frame header.
  int? verticalScale;

  /// Encoded color-space flag, where zero denotes YCbCr.
  int? colorSpace;

  /// Whether reconstructed samples are clamped.
  int? clampType;

  /// Creates empty picture-header state.
  _Vp8PictureHeader();
}

/// Stores segmentation options that modify quantization and filtering.
final class _Vp8SegmentHeader {
  /// Whether the frame uses segmentation.
  bool usesSegmentation = false;

  /// Whether this frame updates the segment map.
  bool updatesMap = false;

  /// Whether segment values are absolute instead of deltas.
  bool usesAbsoluteValues = true;

  /// Quantizer adjustment for each segment.
  final Int8List quantizerAdjustments = Int8List(_Vp8Decoder._segmentCount);

  /// Filter strength for each segment.
  final Int8List filterStrengths = Int8List(_Vp8Decoder._segmentCount);

  /// Creates default segmentation state.
  _Vp8SegmentHeader();
}

/// Stores coefficient probabilities for one frequency band.
final class _Vp8BandProbabilities {
  /// Probabilities indexed by coefficient context and syntax node.
  final List<Uint8List> probabilities;

  /// Creates zero-filled probabilities for every coefficient context.
  _Vp8BandProbabilities()
    : probabilities = List<Uint8List>.generate(
        _Vp8Decoder._coefficientContextCount,
        (_) => Uint8List(_Vp8Decoder._coefficientProbabilityCount),
        growable: false,
      );
}

/// Stores probabilities that persist throughout one lossy VP8 frame.
final class _Vp8Probabilities {
  /// Segment-tree probabilities.
  final Uint8List segmentProbabilities = Uint8List(_Vp8Decoder._segmentProbabilityCount);

  /// Coefficient probabilities indexed by block type and frequency band.
  final List<List<_Vp8BandProbabilities>> bandProbabilities;

  /// Creates default probabilities for every block type and frequency band.
  _Vp8Probabilities()
    : bandProbabilities = List<List<_Vp8BandProbabilities>>.generate(
        _Vp8Decoder._coefficientTypeCount,
        (_) => List<_Vp8BandProbabilities>.generate(
          _Vp8Decoder._coefficientBandCount,
          (_) => _Vp8BandProbabilities(),
          growable: false,
        ),
        growable: false,
      ) {
    segmentProbabilities.fillRange(0, segmentProbabilities.length, 255);
  }
}

/// Stores the loop-filter configuration for one lossy VP8 frame.
final class _Vp8FilterHeader {
  /// Whether the frame selects the simple filter.
  late bool isSimple;

  /// Base filter level from zero through 63.
  int? level;

  /// Filter sharpness from zero through seven.
  late int sharpness;

  /// Whether reference and prediction modes modify the filter level.
  late bool usesLevelDeltas;

  /// Filter-level deltas indexed by reference frame.
  final Int32List referenceLevelDeltas = Int32List(_Vp8Decoder._referenceFilterDeltaCount);

  /// Filter-level deltas indexed by prediction mode.
  final Int32List modeLevelDeltas = Int32List(_Vp8Decoder._modeFilterDeltaCount);

  /// Creates empty loop-filter state.
  _Vp8FilterHeader();
}

/// Stores loop-filter limits derived for one macroblock segment.
final class _Vp8FilterInfo {
  /// Outer-edge filter limit, or zero when filtering is disabled.
  int limit = 0;

  /// Inner-edge filter limit.
  int? innerLevel = 0;

  /// Whether inner edges are filtered.
  bool usesInnerFiltering = false;

  /// High-edge-variance threshold from zero through two.
  int highEdgeVarianceThreshold = 0;

  /// Creates disabled filter information.
  _Vp8FilterInfo();
}

/// Stores neighboring non-zero coefficient contexts for one macroblock.
final class _Vp8MacroBlock {
  /// Packed luma and chroma non-zero coefficient contexts.
  int nonZeroCoefficients = 0;

  /// Non-zero direct-current coefficient context.
  int nonZeroDirectCurrent = 0;

  /// Creates zeroed coefficient contexts.
  _Vp8MacroBlock();
}

/// Stores dequantization values for one segment.
final class _Vp8QuantizationMatrix {
  /// Luminance dequantization values.
  final Int32List luminanceMatrix = Int32List(2);

  /// Secondary luminance direct-current dequantization values.
  final Int32List directCurrentMatrix = Int32List(2);

  /// Chroma dequantization values.
  final Int32List chrominanceMatrix = Int32List(2);

  /// Chroma quantizer index.
  int? chrominanceQuantizer;

  /// Optional local dithering amplitude.
  int? dithering;

  /// Creates zero-filled dequantization values.
  _Vp8QuantizationMatrix();
}

/// Stores coefficients and prediction modes for one macroblock.
final class _Vp8MacroBlockData {
  /// Coefficients for sixteen luma and eight chroma blocks.
  final Int16List coefficients = Int16List(384);

  /// Whether luma uses sixteen independent 4 by 4 predictions.
  late bool isIntra4x4;

  /// Luma prediction modes in decoding order.
  final Uint8List intraModes = Uint8List(16);

  /// Chroma prediction mode.
  int? chrominanceMode;

  /// Packed luma coefficient occupancy.
  int? nonZeroLuminance;

  /// Packed chroma coefficient occupancy.
  late int nonZeroChrominance;

  /// Local dithering strength derived from coefficient occupancy.
  int? dithering;

  /// Creates zero-filled macroblock state.
  _Vp8MacroBlockData();
}

/// Stores reconstructed samples above one macroblock.
final class _Vp8TopSamples {
  /// Sixteen luma samples.
  final Uint8List y = Uint8List(16);

  /// Eight blue-difference chroma samples.
  final Uint8List u = Uint8List(8);

  /// Eight red-difference chroma samples.
  final Uint8List v = Uint8List(8);

  /// Creates zero-filled neighboring samples.
  _Vp8TopSamples();
}
