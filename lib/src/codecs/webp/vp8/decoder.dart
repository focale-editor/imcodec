part of '../../webp.dart';

// WebP lossy format.
/// Decodes a lossy VP8 payload into RGBA pixels.
final class _Vp8Decoder {
  /// Encoded VP8 payload being consumed.
  final _WebPBuffer input;

  /// Shared WebP dimensions and alpha metadata.
  final _WebPDecodingInfo information;

  /// Offsets of the sixteen luma blocks in the reconstruction buffer.
  static const _blockOffsets = <int>[
    0 + 0 * reconstructionStride,
    4 + 0 * reconstructionStride,
    8 + 0 * reconstructionStride,
    12 + 0 * reconstructionStride,
    0 + 4 * reconstructionStride,
    4 + 4 * reconstructionStride,
    8 + 4 * reconstructionStride,
    12 + 4 * reconstructionStride,
    0 + 8 * reconstructionStride,
    4 + 8 * reconstructionStride,
    8 + 8 * reconstructionStride,
    12 + 8 * reconstructionStride,
    0 + 12 * reconstructionStride,
    4 + 12 * reconstructionStride,
    8 + 12 * reconstructionStride,
    12 + 12 * reconstructionStride,
  ];

  // _filterExtraRows[] = How many extra lines are needed on the MB boundary
  // for caching, given a filtering level.
  // Simple filter:  up to 2 luma samples are read and 1 is written.
  // Complex filter: up to 4 luma samples are read and 3 are written. Same for
  //                U/V, so it's 8 samples total (because of the 2x upsampling).
  /// Extra cached luma rows required by each filter mode.
  static const List<int> _filterExtraRows = [0, 2, 8];

  /// Probability band selected by each coefficient position.
  static const List<int> _coefficientBands = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0];

  /// Probabilities for category-three coefficient magnitudes.
  static const List<int> _category3Probabilities = [173, 148, 140];

  /// Probabilities for category-four coefficient magnitudes.
  static const List<int> _category4Probabilities = [176, 155, 140, 135];

  /// Probabilities for category-five coefficient magnitudes.
  static const List<int> _category5Probabilities = [180, 157, 141, 134, 130];

  /// Probabilities for category-six coefficient magnitudes.
  static const List<int> _category6Probabilities = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129];

  /// Magnitude probabilities indexed by coefficient category.
  static const List<List<int>> _largeCoefficientProbabilities = [_category3Probabilities, _category4Probabilities, _category5Probabilities, _category6Probabilities];

  /// Mapping from coded coefficient order to transform-block order.
  static const List<int> _zigzagOrder = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];

  // Main data source
  /// Boolean decoder for the first VP8 partition.
  late _Vp8BitReader bitReader;

  /// RGBA image receiving decoded pixels.
  Image? _output;

  /// Inverse-transform and in-loop-filter operations.
  late _Vp8Filter _filter;

  // headers
  /// Parsed VP8 frame header.
  final _frameHeader = _Vp8FrameHeader();

  /// Parsed VP8 picture dimensions and scaling.
  final _pictureHeader = _Vp8PictureHeader();

  /// Parsed in-loop-filter configuration.
  final _filterHeader = _Vp8FilterHeader();

  /// Parsed macroblock segmentation configuration.
  final _segmentHeader = _Vp8SegmentHeader();

  /// Left edge of the decoded crop in pixels.
  late int _cropLeftPixel;

  /// Exclusive right edge of the decoded crop in pixels.
  late int _cropRightPixel;

  /// Top edge of the decoded crop in pixels.
  int? _cropTopPixel;

  /// Exclusive bottom edge of the decoded crop in pixels.
  int? _cropBottomPixel;

  // Width in macroblock units.
  /// Frame width in sixteen-pixel macroblocks.
  int? _macroblockWidth;

  // Height in macroblock units.
  /// Frame height in sixteen-pixel macroblocks.
  int? _macroblockHeight;

  // Macroblock to process/filter, depending on cropping and filter_type.
  /// First horizontal macroblock that requires filtering.
  late int _topLeftMacroblockX; // top-left MB that must be in-loop filtered

  /// First vertical macroblock that requires filtering.
  late int _topLeftMacroblockY;

  /// Exclusive horizontal macroblock decode limit.
  int? _bottomRightMacroblockX; // last bottom-right MB that must be decoded

  /// Exclusive vertical macroblock decode limit.
  int? _bottomRightMacroblockY;

  // number of partitions.
  /// Number of coefficient-data partitions.
  late int _partitionCount;

  // per-partition boolean decoders.
  /// Boolean decoders for coefficient-data partitions.
  final _partitions = List<_Vp8BitReader?>.filled(_maximumPartitionCount, null);

  // dequantization (one set of DC/AC dequant factor per segment)
  /// Per-segment luma and chroma quantization factors.
  final _quantizationMatrices = List<_Vp8QuantizationMatrix?>.filled(_segmentCount, null);

  // probabilities
  /// Adaptive probabilities used by the current frame.
  _Vp8Probabilities? _probabilities;

  /// Whether macroblocks carry an explicit skip flag.
  late bool _usesSkipProbability;

  /// Probability used to decode macroblock skip flags.
  late int _skipProbability;

  // Boundary data cache and persistent buffers.
  // top intra modes values: 4 * _macroblockWidth
  /// Cached intra-prediction modes above the current macroblock.
  Uint8List? _topIntraModes;

  // left intra modes values
  /// Cached intra-prediction modes left of the current macroblock.
  final _leftIntraModes = Uint8List(4);

  // uint8, segment of the currently parsed block
  /// Segment selected for the current macroblock.
  late int _segmentIndex;

  // top y/u/v samples
  /// Cached luma and chroma samples above each macroblock.
  late List<_Vp8TopSamples> _topSamples;

  // contextual macroblock info (mb_w_ + 1)
  /// Prediction context for the current macroblock row.
  late List<_Vp8MacroBlock> _macroblockInformation;

  // filter strength info
  /// Filter parameters for the current macroblock row.
  late List<_Vp8FilterInfo?> _filterInformation;

  // main block for Y/U/V (size = YUV_SIZE)
  /// Working luma and chroma reconstruction buffer.
  late Uint8List _sampleBlock;

  // macroblock row for storing unfiltered samples
  /// Unfiltered luma rows retained across macroblock rows.
  late _WebPBuffer _lumaCache;

  /// Unfiltered blue-difference rows retained across macroblock rows.
  late _WebPBuffer _blueDifferenceCache;

  /// Unfiltered red-difference rows retained across macroblock rows.
  late _WebPBuffer _redDifferenceCache;

  /// Row stride of the luma cache.
  int? _lumaCacheStride;

  /// Row stride of each chroma cache.
  int? _chromaCacheStride;

  /// Unfinished luma row retained for chroma upsampling.
  late _WebPBuffer _temporaryLuma;

  /// Unfinished blue-difference row retained for upsampling.
  late _WebPBuffer _temporaryBlueDifference;

  /// Unfinished red-difference row retained for upsampling.
  late _WebPBuffer _temporaryRedDifference;

  /// Visible luma rows prepared for output conversion.
  late _WebPBuffer _luma;

  /// Visible blue-difference rows prepared for output conversion.
  late _WebPBuffer _blueDifference;

  /// Visible red-difference rows prepared for output conversion.
  late _WebPBuffer _redDifference;

  /// Decoded alpha rows aligned with the current output rows.
  _WebPBuffer? _alphaRows;

  // Per macroblock non-persistent infos.
  // current position, in macroblock units
  /// Horizontal index of the macroblock being decoded.
  int _macroblockX = 0;

  /// Vertical index of the macroblock row being decoded.
  int _macroblockY = 0;

  // parsed reconstruction data
  /// Residual and prediction data for the current macroblock row.
  late List<_Vp8MacroBlockData> _macroblockData;

  // 0=off, 1=simple, 2=complex
  /// Active filter mode: disabled, simple, or normal.
  int? _filterType;

  // precalculated per-segment/type
  /// Precomputed filter strengths by segment and prediction mode.
  late List<List<_Vp8FilterInfo>> _filterStrengths;

  // Alpha
  // alpha-plane decoder object
  /// Decoder for a compressed alpha chunk.
  late _WebPAlphaDecoder _alphaDecoder;

  // compressed alpha data (if present)
  /// Compressed alpha payload, when present.
  _WebPBuffer? _compressedAlpha;

  /// Complete decoded alpha plane.
  late Uint8List _decodedAlpha;

  /// Decision tree for four-by-four intra-prediction modes.
  static const List<int> _intra4ModeTree = [
    -_intra4DirectCurrent,
    1,
    -_intra4TrueMotion,
    2,
    -_intra4Vertical,
    3,
    4,
    6,
    -_intra4Horizontal,
    5,
    -_intra4DownRight,
    -_intra4VerticalRight,
    -_intra4DownLeft,
    7,
    -_intra4VerticalLeft,
    8,
    -_intra4HorizontalDown,
    -_intra4HorizontalUp,
  ];

  /// Four-by-four intra-mode probabilities indexed by neighboring modes.
  static const _intra4ModeProbabilities = [
    [
      [231, 120, 48, 89, 115, 113, 120, 152, 112],
      [152, 179, 64, 126, 170, 118, 46, 70, 95],
      [175, 69, 143, 80, 85, 82, 72, 155, 103],
      [56, 58, 10, 171, 218, 189, 17, 13, 152],
      [114, 26, 17, 163, 44, 195, 21, 10, 173],
      [121, 24, 80, 195, 26, 62, 44, 64, 85],
      [144, 71, 10, 38, 171, 213, 144, 34, 26],
      [170, 46, 55, 19, 136, 160, 33, 206, 71],
      [63, 20, 8, 114, 114, 208, 12, 9, 226],
      [81, 40, 11, 96, 182, 84, 29, 16, 36],
    ],
    [
      [134, 183, 89, 137, 98, 101, 106, 165, 148],
      [72, 187, 100, 130, 157, 111, 32, 75, 80],
      [66, 102, 167, 99, 74, 62, 40, 234, 128],
      [41, 53, 9, 178, 241, 141, 26, 8, 107],
      [74, 43, 26, 146, 73, 166, 49, 23, 157],
      [65, 38, 105, 160, 51, 52, 31, 115, 128],
      [104, 79, 12, 27, 217, 255, 87, 17, 7],
      [87, 68, 71, 44, 114, 51, 15, 186, 23],
      [47, 41, 14, 110, 182, 183, 21, 17, 194],
      [66, 45, 25, 102, 197, 189, 23, 18, 22],
    ],
    [
      [88, 88, 147, 150, 42, 46, 45, 196, 205],
      [43, 97, 183, 117, 85, 38, 35, 179, 61],
      [39, 53, 200, 87, 26, 21, 43, 232, 171],
      [56, 34, 51, 104, 114, 102, 29, 93, 77],
      [39, 28, 85, 171, 58, 165, 90, 98, 64],
      [34, 22, 116, 206, 23, 34, 43, 166, 73],
      [107, 54, 32, 26, 51, 1, 81, 43, 31],
      [68, 25, 106, 22, 64, 171, 36, 225, 114],
      [34, 19, 21, 102, 132, 188, 16, 76, 124],
      [62, 18, 78, 95, 85, 57, 50, 48, 51],
    ],
    [
      [193, 101, 35, 159, 215, 111, 89, 46, 111],
      [60, 148, 31, 172, 219, 228, 21, 18, 111],
      [112, 113, 77, 85, 179, 255, 38, 120, 114],
      [40, 42, 1, 196, 245, 209, 10, 25, 109],
      [88, 43, 29, 140, 166, 213, 37, 43, 154],
      [61, 63, 30, 155, 67, 45, 68, 1, 209],
      [100, 80, 8, 43, 154, 1, 51, 26, 71],
      [142, 78, 78, 16, 255, 128, 34, 197, 171],
      [41, 40, 5, 102, 211, 183, 4, 1, 221],
      [51, 50, 17, 168, 209, 192, 23, 25, 82],
    ],
    [
      [138, 31, 36, 171, 27, 166, 38, 44, 229],
      [67, 87, 58, 169, 82, 115, 26, 59, 179],
      [63, 59, 90, 180, 59, 166, 93, 73, 154],
      [40, 40, 21, 116, 143, 209, 34, 39, 175],
      [47, 15, 16, 183, 34, 223, 49, 45, 183],
      [46, 17, 33, 183, 6, 98, 15, 32, 183],
      [57, 46, 22, 24, 128, 1, 54, 17, 37],
      [65, 32, 73, 115, 28, 128, 23, 128, 205],
      [40, 3, 9, 115, 51, 192, 18, 6, 223],
      [87, 37, 9, 115, 59, 77, 64, 21, 47],
    ],
    [
      [104, 55, 44, 218, 9, 54, 53, 130, 226],
      [64, 90, 70, 205, 40, 41, 23, 26, 57],
      [54, 57, 112, 184, 5, 41, 38, 166, 213],
      [30, 34, 26, 133, 152, 116, 10, 32, 134],
      [39, 19, 53, 221, 26, 114, 32, 73, 255],
      [31, 9, 65, 234, 2, 15, 1, 118, 73],
      [75, 32, 12, 51, 192, 255, 160, 43, 51],
      [88, 31, 35, 67, 102, 85, 55, 186, 85],
      [56, 21, 23, 111, 59, 205, 45, 37, 192],
      [55, 38, 70, 124, 73, 102, 1, 34, 98],
    ],
    [
      [125, 98, 42, 88, 104, 85, 117, 175, 82],
      [95, 84, 53, 89, 128, 100, 113, 101, 45],
      [75, 79, 123, 47, 51, 128, 81, 171, 1],
      [57, 17, 5, 71, 102, 57, 53, 41, 49],
      [38, 33, 13, 121, 57, 73, 26, 1, 85],
      [41, 10, 67, 138, 77, 110, 90, 47, 114],
      [115, 21, 2, 10, 102, 255, 166, 23, 6],
      [101, 29, 16, 10, 85, 128, 101, 196, 26],
      [57, 18, 10, 102, 102, 213, 34, 20, 43],
      [117, 20, 15, 36, 163, 128, 68, 1, 26],
    ],
    [
      [102, 61, 71, 37, 34, 53, 31, 243, 192],
      [69, 60, 71, 38, 73, 119, 28, 222, 37],
      [68, 45, 128, 34, 1, 47, 11, 245, 171],
      [62, 17, 19, 70, 146, 85, 55, 62, 70],
      [37, 43, 37, 154, 100, 163, 85, 160, 1],
      [63, 9, 92, 136, 28, 64, 32, 201, 85],
      [75, 15, 9, 9, 64, 255, 184, 119, 16],
      [86, 6, 28, 5, 64, 255, 25, 248, 1],
      [56, 8, 17, 132, 137, 255, 55, 116, 128],
      [58, 15, 20, 82, 135, 57, 26, 121, 40],
    ],
    [
      [164, 50, 31, 137, 154, 133, 25, 35, 218],
      [51, 103, 44, 131, 131, 123, 31, 6, 158],
      [86, 40, 64, 135, 148, 224, 45, 183, 128],
      [22, 26, 17, 131, 240, 154, 14, 1, 209],
      [45, 16, 21, 91, 64, 222, 7, 1, 197],
      [56, 21, 39, 155, 60, 138, 23, 102, 213],
      [83, 12, 13, 54, 192, 255, 68, 47, 28],
      [85, 26, 85, 85, 128, 128, 32, 146, 171],
      [18, 11, 7, 63, 144, 171, 4, 4, 246],
      [35, 27, 10, 146, 174, 171, 12, 26, 128],
    ],
    [
      [190, 80, 35, 99, 180, 80, 126, 54, 45],
      [85, 126, 47, 87, 176, 51, 41, 20, 32],
      [101, 75, 128, 139, 118, 146, 116, 128, 85],
      [56, 41, 15, 176, 236, 85, 37, 9, 62],
      [71, 30, 17, 119, 118, 255, 17, 18, 138],
      [101, 38, 60, 138, 55, 70, 43, 26, 142],
      [146, 36, 19, 30, 171, 255, 97, 27, 20],
      [138, 45, 61, 62, 219, 1, 81, 188, 64],
      [32, 41, 20, 117, 151, 142, 20, 21, 163],
      [112, 19, 12, 61, 195, 128, 48, 4, 24],
    ],
  ];

  /// Default coefficient probabilities from the VP8 specification.
  static const _defaultCoefficientProbabilities = [
    [
      [
        [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
        [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
        [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
      ],
      [
        [253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128],
        [189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128],
        [106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128],
      ],
      [
        [1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128],
        [181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128],
        [78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128],
      ],
      [
        [1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128],
        [184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128],
        [77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128],
      ],
      [
        [1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128],
        [170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128],
        [37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128],
      ],
      [
        [1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128],
        [207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128],
        [102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128],
      ],
      [
        [1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128],
        [177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128],
        [80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128],
      ],
      [
        [1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128],
        [246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128],
        [255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
      ],
    ],
    [
      [
        [198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62],
        [131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1],
        [68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128],
      ],
      [
        [1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128],
        [184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128],
        [81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128],
      ],
      [
        [1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128],
        [99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128],
        [23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128],
      ],
      [
        [1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128],
        [109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128],
        [44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128],
      ],
      [
        [1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128],
        [94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128],
        [22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128],
      ],
      [
        [1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128],
        [124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128],
        [35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128],
      ],
      [
        [1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128],
        [121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128],
        [45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128],
      ],
      [
        [1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128],
        [203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128],
        [137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128],
      ],
    ],
    [
      [
        [253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128],
        [175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128],
        [73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128],
      ],
      [
        [1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128],
        [239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128],
        [155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128],
      ],
      [
        [1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128],
        [201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128],
        [69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128],
      ],
      [
        [1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128],
        [223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128],
        [141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128],
      ],
      [
        [1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128],
        [190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128],
        [149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128],
      ],
      [
        [1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128],
        [247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128],
        [240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128],
      ],
      [
        [1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128],
        [213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128],
        [55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128],
      ],
      [
        [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
        [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
        [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128],
      ],
    ],
    [
      [
        [202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255],
        [126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128],
        [61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128],
      ],
      [
        [1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128],
        [166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128],
        [39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128],
      ],
      [
        [1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128],
        [124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128],
        [24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128],
      ],
      [
        [1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128],
        [149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128],
        [28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128],
      ],
      [
        [1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128],
        [123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128],
        [20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128],
      ],
      [
        [1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128],
        [168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128],
        [47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128],
      ],
      [
        [1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128],
        [141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128],
        [42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128],
      ],
      [
        [1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128],
        [244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128],
        [238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128],
      ],
    ],
  ];

  /// Probabilities governing coefficient-probability updates.
  static const _coefficientUpdateProbabilities = [
    [
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255],
        [249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255],
        [234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255],
        [250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255],
        [254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
    ],
    [
      [
        [217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255],
        [234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255],
      ],
      [
        [255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255],
        [250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
    ],
    [
      [
        [186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255],
        [234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255],
        [251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255],
      ],
      [
        [255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
    ],
    [
      [
        [248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255],
        [248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255],
        [246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255],
        [252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255],
        [248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255],
        [253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255],
        [252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255],
        [250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
      [
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ],
    ],
  ];

  // Paragraph 14.1
  /// Direct-current quantizers indexed by quantizer level.
  static const _directCurrentQuantizers = [
    // uint8
    4, 5, 6, 7, 8, 9, 10, 10,
    11, 12, 13, 14, 15, 16, 17, 17,
    18, 19, 20, 20, 21, 21, 22, 22,
    23, 23, 24, 25, 25, 26, 27, 28,
    29, 30, 31, 32, 33, 34, 35, 36,
    37, 37, 38, 39, 40, 41, 42, 43,
    44, 45, 46, 46, 47, 48, 49, 50,
    51, 52, 53, 54, 55, 56, 57, 58,
    59, 60, 61, 62, 63, 64, 65, 66,
    67, 68, 69, 70, 71, 72, 73, 74,
    75, 76, 76, 77, 78, 79, 80, 81,
    82, 83, 84, 85, 86, 87, 88, 89,
    91, 93, 95, 96, 98, 100, 101, 102,
    104, 106, 108, 110, 112, 114, 116, 118,
    122, 124, 126, 128, 130, 132, 134, 136,
    138, 140, 143, 145, 148, 151, 154, 157,
  ];

  /// Alternating-current quantizers indexed by quantizer level.
  static const _alternatingCurrentQuantizers = [
    // uint16
    4, 5, 6, 7, 8, 9, 10, 11,
    12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27,
    28, 29, 30, 31, 32, 33, 34, 35,
    36, 37, 38, 39, 40, 41, 42, 43,
    44, 45, 46, 47, 48, 49, 50, 51,
    52, 53, 54, 55, 56, 57, 58, 60,
    62, 64, 66, 68, 70, 72, 74, 76,
    78, 80, 82, 84, 86, 88, 90, 92,
    94, 96, 98, 100, 102, 104, 106, 108,
    110, 112, 114, 116, 119, 122, 125, 128,
    131, 134, 137, 140, 143, 146, 149, 152,
    155, 158, 161, 164, 167, 170, 173, 177,
    181, 185, 189, 193, 197, 201, 205, 209,
    213, 217, 221, 225, 229, 234, 239, 245,
    249, 254, 259, 264, 269, 274, 279, 284,
  ];

  /// Three-byte signature identifying a VP8 key frame.
  static const _keyFrameSignature = 0x2a019d;

  /// Number of probabilities in the segment decision tree.
  static const _segmentProbabilityCount = 3;

  /// Maximum number of VP8 macroblock segments.
  static const _segmentCount = 4;

  /// Number of reference-frame filter deltas.
  static const _referenceFilterDeltaCount = 4;

  /// Number of prediction-mode filter deltas.
  static const _modeFilterDeltaCount = 4; // I4x4, ZERO, *, SPLIT

  /// Maximum number of coefficient-data partitions.
    static const _maximumPartitionCount = 8;

  /// Identifier for four-by-four direct-current prediction.
    static const _intra4DirectCurrent = 0; // 4x4 modes

  /// Identifier for four-by-four true-motion prediction.
    static const _intra4TrueMotion = 1;

  /// Identifier for four-by-four vertical prediction.
    static const _intra4Vertical = 2;

  /// Identifier for four-by-four horizontal prediction.
    static const _intra4Horizontal = 3;

  /// Identifier for four-by-four down-right prediction.
    static const _intra4DownRight = 4;

  /// Identifier for four-by-four vertical-right prediction.
    static const _intra4VerticalRight = 5;

  /// Identifier for four-by-four down-left prediction.
    static const _intra4DownLeft = 6;

  /// Identifier for four-by-four vertical-left prediction.
    static const _intra4VerticalLeft = 7;

  /// Identifier for four-by-four horizontal-down prediction.
    static const _intra4HorizontalDown = 8;

  /// Identifier for four-by-four horizontal-up prediction.
    static const _intra4HorizontalUp = 9;

  // Luma16 or UV modes
  /// Identifier for macroblock direct-current prediction.
    static const int _directCurrentPrediction = _intra4DirectCurrent;

  /// Identifier for macroblock vertical prediction.
    static const int _verticalPrediction = _intra4Vertical;

  /// Identifier for macroblock horizontal prediction.
    static const int _horizontalPrediction = _intra4Horizontal;

  /// Identifier for macroblock true-motion prediction.
    static const int _trueMotionPrediction = _intra4TrueMotion;

  // special modes
  /// Direct-current mode used without top neighbors.
    static const _directCurrentWithoutTop = 4;

  /// Direct-current mode used without left neighbors.
    static const _directCurrentWithoutLeft = 5;

  /// Direct-current mode used without any neighbors.
    static const _directCurrentWithoutNeighbors = 6;

  // Probabilities
  /// Number of coefficient block types.
    static const _coefficientTypeCount = 4;

  /// Number of coefficient probability bands.
    static const _coefficientBandCount = 8;

  /// Number of neighboring-coefficient contexts.
    static const _coefficientContextCount = 3;

  /// Number of decisions in a coefficient probability node.
    static const _coefficientProbabilityCount = 11;

  /// Shared row stride of the reconstruction buffer.
    static const reconstructionStride = 32; // this is the common stride used by yuv[]

  /// Number of samples in the reconstruction buffer.
    static const int _reconstructionBufferSize = reconstructionStride * 17 + reconstructionStride * 9;

  /// Luma-plane offset in the reconstruction buffer.
    static const int _lumaOffset = reconstructionStride * 1 + 8;

  /// Blue-difference-plane offset in the reconstruction buffer.
    static const int _blueDifferenceOffset = _lumaOffset + reconstructionStride * 16 + reconstructionStride;

  /// Red-difference-plane offset in the reconstruction buffer.
    static const int _redDifferenceOffset = _blueDifferenceOffset + 16;

  /// Fractional precision of fixed-point YUV conversion.
    static const _colorConversionFractionBits = 14; // fixed-point precision for YUV->RGB

  /// Rounding term for fixed-point YUV conversion.
    static const int _colorConversionRounding = 1 << (_colorConversionFractionBits - 1);

  /// Mask covering the valid fixed-point color range.
    static const int _colorConversionMask = (256 << _colorConversionFractionBits) - 1;

  /// Complement of the fixed-point color mask.
    static const int _inverseColorConversionMask = -_colorConversionMask - 1;

  // These constants are 14b fixed-point version of ITU-R BT.601 constants.
  /// Fixed-point scale converting limited-range luma.
    static const _lumaScale = 19077; // 1.164 = 255 / 219

  /// Fixed-point red-difference contribution to red.
    static const _redDifferenceToRed = 26149; // 1.596 = 255 / 112 * 0.701

  /// Fixed-point blue-difference contribution to green.
    static const _blueDifferenceToGreen = 6419; // 0.391 = 255 / 112 * 0.886 * 0.114 / 0.587

  /// Fixed-point red-difference contribution to green.
    static const _redDifferenceToGreen = 13320; // 0.813 = 255 / 112 * 0.701 * 0.299 / 0.587

  /// Fixed-point blue-difference contribution to blue.
    static const _blueDifferenceToBlue = 33050; // 2.018 = 255 / 112 * 0.886

  /// Fixed-point offset applied while reconstructing red.
    static const int _redConversionOffset = -_lumaScale * 16 - _redDifferenceToRed * 128 + _colorConversionRounding;

  /// Fixed-point offset applied while reconstructing green.
    static const int _greenConversionOffset = -_lumaScale * 16 + _blueDifferenceToGreen * 128 + _redDifferenceToGreen * 128 + _colorConversionRounding;

  /// Fixed-point offset applied while reconstructing blue.
    static const int _blueConversionOffset = -_lumaScale * 16 - _blueDifferenceToBlue * 128 + _colorConversionRounding;

  /// Creates a decoder over one lossy VP8 payload.
    _Vp8Decoder({
    required this.input,
    required this.information,
  });

  /// Reads the uncompressed VP8 key-frame header.
    bool _decodeHeader() {
    final int bits = input.readUint24();

    final keyFrame = (bits & 1) == 0;
    if (!keyFrame) {
      return false;
    }

    if (((bits >> 1) & 7) > 3) {
      return false; // unknown profile
    }

    if (((bits >> 4) & 1) == 0) {
      return false; // first frame is invisible!
    }

    _frameHeader
      ..isKeyFrame = (bits & 1) == 0
      ..profile = (bits >> 1) & 7
      ..isVisible = ((bits >> 4) & 1) != 0
      ..partitionLength = bits >> 5;

    final int signature = input.readUint24();
    if (signature != _keyFrameSignature) {
      return false;
    }

    information
      ..width = input.readUint16() & 0x3fff
      ..height = input.readUint16() & 0x3fff
      ..format = _WebPFormat.lossy;

    return true;
  }

  /// Decodes the payload, returning null when its VP8 data is invalid.
    Image? decode() {
    if (!_readHeaders()) {
      return null;
    }

    _output = Image(width: information.width, height: information.height);

    // Will allocate memory and prepare everything.
    if (!_initializeFrame()) {
      return null;
    }

    // Main decoding loop
    if (!_parseFrame()) {
      return null;
    }

    return _output;
  }

  /// Reads all frame headers and coefficient partitions.
    bool _readHeaders() {
    if (!_decodeHeader()) {
      return false;
    }

    _probabilities = _Vp8Probabilities();
    for (var i = 0; i < _segmentCount; ++i) {
      _quantizationMatrices[i] = _Vp8QuantizationMatrix();
    }

    _pictureHeader
      ..width = information.width
      ..height = information.height
      ..horizontalScale = (information.width >> 8) >> 6
      ..verticalScale = (information.height >> 8) >> 6;

    _cropTopPixel = 0;
    _cropLeftPixel = 0;
    _cropRightPixel = information.width;
    _cropBottomPixel = information.height;

    _macroblockWidth = (information.width + 15) >> 4;
    _macroblockHeight = (information.height + 15) >> 4;

    _segmentIndex = 0;

    bitReader = _Vp8BitReader(input: input.subset(_frameHeader.partitionLength));
    input.skip(_frameHeader.partitionLength);

    _pictureHeader
      ..colorSpace = bitReader.readBoolean()
      ..clampType = bitReader.readBoolean();

    if (!_parseSegmentHeader(_segmentHeader, _probabilities)) {
      return false;
    }

    // Filter specs
    if (!_parseFilterHeader()) {
      return false;
    }

    if (!_parsePartitions(input)) {
      return false;
    }

    // quantizer change
    _parseQuant();

    // Frame buffer marking
    bitReader.readBoolean(); // ignore the value of update_proba_

    _parseProbabilities();

    return true;
  }

  /// Reads macroblock segmentation settings.
    bool _parseSegmentHeader(_Vp8SegmentHeader hdr, _Vp8Probabilities? proba) {
    hdr.usesSegmentation = bitReader.readBoolean() != 0;
    if (hdr.usesSegmentation) {
      hdr.updatesMap = bitReader.readBoolean() != 0;
      if (bitReader.readBoolean() != 0) {
        // update data
        hdr.usesAbsoluteValues = bitReader.readBoolean() != 0;
        for (var s = 0; s < _segmentCount; ++s) {
          hdr.quantizerAdjustments[s] = bitReader.readBoolean() != 0 ? bitReader.readSignedBits(7) : 0;
        }
        for (var s = 0; s < _segmentCount; ++s) {
          hdr.filterStrengths[s] = bitReader.readBoolean() != 0 ? bitReader.readSignedBits(6) : 0;
        }
      }
      if (hdr.updatesMap) {
        for (var s = 0; s < _segmentProbabilityCount; ++s) {
          proba!.segmentProbabilities[s] = bitReader.readBoolean() != 0 ? bitReader.readBits(8) : 255;
        }
      }
    } else {
      hdr.updatesMap = false;
    }

    return true;
  }

  /// Reads in-loop-filter settings.
    bool _parseFilterHeader() {
    final _Vp8FilterHeader hdr = _filterHeader
      ..isSimple = bitReader.readBoolean() != 0
      ..level = bitReader.readBits(6)
      ..sharpness = bitReader.readBits(3)
      ..usesLevelDeltas = bitReader.readBoolean() != 0;
    if (hdr.usesLevelDeltas) {
      if (bitReader.readBoolean() != 0) {
        // update lf-delta?
        for (var i = 0; i < _referenceFilterDeltaCount; ++i) {
          if (bitReader.readBoolean() != 0) {
            hdr.referenceLevelDeltas[i] = bitReader.readSignedBits(6);
          }
        }

        for (var i = 0; i < _modeFilterDeltaCount; ++i) {
          if (bitReader.readBoolean() != 0) {
            hdr.modeLevelDeltas[i] = bitReader.readSignedBits(6);
          }
        }
      }
    }

    _filterType = (hdr.level == 0)
        ? 0
        : hdr.isSimple
        ? 1
        : 2;

    return true;
  }

  // This function returns VP8_STATUS_SUSPENDED if we don't have all the
  // necessary data in 'buf'.
  // This case is not necessarily an error (for incremental decoding).
  // Still, no bitreader is ever initialized to make it possible to read
  // unavailable memory.
  // If we don't even have the partitions' sizes, than
  // VP8_STATUS_NOT_ENOUGH_DATA is returned, and this is an unrecoverable error.
  // If the partitions were positioned ok, VP8_STATUS_OK is returned.
  /// Splits coefficient data into Boolean-coded partitions.
    bool _parsePartitions(_WebPBuffer input) {
    var sz = 0;
    final int bufEnd = input.length;

    _partitionCount = 1 << bitReader.readBits(2);
    final int lastPart = _partitionCount - 1;
    int partStart = lastPart * 3;
    if (bufEnd < partStart) {
      // we can't even read the sizes with sz[]! That's a failure.
      return false;
    }

    for (var p = 0; p < lastPart; ++p) {
      final _WebPBuffer szb = input.peekBytes(3, sz);
      final int psize = szb[0] | (szb[1] << 8) | (szb[2] << 16);
      int partEnd = partStart + psize;
      if (partEnd > bufEnd) {
        partEnd = bufEnd;
      }

      final _WebPBuffer pin = input.subset(partEnd - partStart, position: partStart);
      _partitions[p] = _Vp8BitReader(input: pin);
      partStart = partEnd;
      sz += 3;
    }

    final _WebPBuffer pin = input.subset(bufEnd - partStart, position: input.position + partStart);
    _partitions[lastPart] = _Vp8BitReader(input: pin);

    // Init is ok, but there's not enough data
    return partStart < bufEnd;
  }

  /// Reads and expands per-segment quantization factors.
    void _parseQuant() {
    final int baseQ0 = bitReader.readBits(7);
    final int dqy1Dc = bitReader.readBoolean() != 0 ? bitReader.readSignedBits(4) : 0;
    final int dqy2Dc = bitReader.readBoolean() != 0 ? bitReader.readSignedBits(4) : 0;
    final int dqy2Ac = bitReader.readBoolean() != 0 ? bitReader.readSignedBits(4) : 0;
    final int dquvDc = bitReader.readBoolean() != 0 ? bitReader.readSignedBits(4) : 0;
    final int dquvAc = bitReader.readBoolean() != 0 ? bitReader.readSignedBits(4) : 0;

    final _Vp8SegmentHeader hdr = _segmentHeader;

    for (var i = 0; i < _segmentCount; ++i) {
      int q;
      if (hdr.usesSegmentation) {
        q = hdr.quantizerAdjustments[i];
        if (!hdr.usesAbsoluteValues) {
          q += baseQ0;
        }
      } else {
        if (i > 0) {
          _quantizationMatrices[i] = _quantizationMatrices[0];
          continue;
        } else {
          q = baseQ0;
        }
      }

      final _Vp8QuantizationMatrix m = _quantizationMatrices[i]!;
      m.luminanceMatrix[0] = _directCurrentQuantizers[_clamp(q + dqy1Dc, 127)];
      m.luminanceMatrix[1] = _alternatingCurrentQuantizers[_clamp(q + 0, 127)];

      m.directCurrentMatrix[0] = _directCurrentQuantizers[_clamp(q + dqy2Dc, 127)] * 2;
      // For all x in [0..284], x*155/100 is bitwise equal to (x*101581) >> 16.
      // The smallest precision for that is '(x*6349) >> 12' but 16 is a good
      // word size.
      m.directCurrentMatrix[1] = (_alternatingCurrentQuantizers[_clamp(q + dqy2Ac, 127)] * 101581) >> 16;
      if (m.directCurrentMatrix[1] < 8) {
        m.directCurrentMatrix[1] = 8;
      }

      m.chrominanceMatrix[0] = _directCurrentQuantizers[_clamp(q + dquvDc, 117)];
      m.chrominanceMatrix[1] = _alternatingCurrentQuantizers[_clamp(q + dquvAc, 127)];

      m.chrominanceQuantizer = q + dquvAc; // for dithering strength evaluation
    }
  }

  /// Reads coefficient and macroblock skip probabilities.
    void _parseProbabilities() {
    final _Vp8Probabilities? proba = _probabilities;
    for (var t = 0; t < _coefficientTypeCount; ++t) {
      for (var b = 0; b < _coefficientBandCount; ++b) {
        for (var c = 0; c < _coefficientContextCount; ++c) {
          for (var p = 0; p < _coefficientProbabilityCount; ++p) {
            final int v = bitReader.readBit(_coefficientUpdateProbabilities[t][b][c][p]) != 0 ? bitReader.readBits(8) : _defaultCoefficientProbabilities[t][b][c][p];
            proba!.bandProbabilities[t][b].probabilities[c][p] = v;
          }
        }
      }
    }

    _usesSkipProbability = bitReader.readBoolean() != 0;
    if (_usesSkipProbability) {
      _skipProbability = bitReader.readBits(8);
    }
  }

  // Precompute the filtering strength for each segment and each i4x4/i16x16
  // mode.
  /// Builds filter strengths for every segment and prediction mode.
    void _precomputeFilterStrengths() {
    if (_filterType! > 0) {
      final _Vp8FilterHeader hdr = _filterHeader;
      for (var s = 0; s < _segmentCount; ++s) {
        // First, compute the initial level
        int? baseLevel;
        if (_segmentHeader.usesSegmentation) {
          baseLevel = _segmentHeader.filterStrengths[s];
          if (!_segmentHeader.usesAbsoluteValues) {
            baseLevel += hdr.level!;
          }
        } else {
          baseLevel = hdr.level;
        }

        for (var i4x4 = 0; i4x4 <= 1; ++i4x4) {
          final _Vp8FilterInfo info = _filterStrengths[s][i4x4];
          var level = baseLevel;
          if (hdr.usesLevelDeltas) {
            level = level! + hdr.referenceLevelDeltas[0];
            if (i4x4 != 0) {
              level += hdr.modeLevelDeltas[0];
            }
          }

          level = (level! < 0)
              ? 0
              : (level > 63)
              ? 63
              : level;
          if (level > 0) {
            int? iLevel = level;
            if (hdr.sharpness > 0) {
              if (hdr.sharpness > 4) {
                iLevel >>= 2;
              } else {
                iLevel >>= 1;
              }

              if (iLevel > 9 - hdr.sharpness) {
                iLevel = 9 - hdr.sharpness;
              }
            }

            if (iLevel < 1) {
              iLevel = 1;
            }

            info
              ..innerLevel = iLevel
              ..limit = 2 * level + iLevel
              ..highEdgeVarianceThreshold = (level >= 40)
                  ? 2
                  : (level >= 15)
                  ? 1
                  : 0;
          } else {
            info.limit = 0; // no filtering
          }

          info.usesInnerFiltering = i4x4 != 0;
        }
      }
    }
  }

  /// Allocates frame-sized caches and initializes row state.
    bool _initializeFrame() {
    if (information.alphaData != null) {
      _compressedAlpha = information.alphaData;
    }

    _filterStrengths = List<List<_Vp8FilterInfo>>.generate(_segmentCount, (i) => [_Vp8FilterInfo(), _Vp8FilterInfo()], growable: false);

    _topSamples = List<_Vp8TopSamples>.generate(_macroblockWidth!, (_) => _Vp8TopSamples(), growable: false);

    _sampleBlock = Uint8List(_reconstructionBufferSize);

    _topIntraModes = Uint8List(4 * _macroblockWidth!);

    _lumaCacheStride = 16 * _macroblockWidth!;
    _chromaCacheStride = 8 * _macroblockWidth!;

    final int extraRows = _filterExtraRows[_filterType!];
    final int extraY = extraRows * _lumaCacheStride!;
    final int extraUv = (extraRows ~/ 2) * _chromaCacheStride!;

    _lumaCache = _WebPBuffer(data: Uint8List(16 * _lumaCacheStride! + extraY), offset: extraY);

    _blueDifferenceCache = _WebPBuffer(data: Uint8List(8 * _chromaCacheStride! + extraUv), offset: extraUv);

    _redDifferenceCache = _WebPBuffer(data: Uint8List(8 * _chromaCacheStride! + extraUv), offset: extraUv);

    _temporaryLuma = _WebPBuffer(data: Uint8List(information.width));

    final int uvWidth = (information.width + 1) >> 1;
    _temporaryBlueDifference = _WebPBuffer(data: Uint8List(uvWidth));
    _temporaryRedDifference = _WebPBuffer(data: Uint8List(uvWidth));

    // Define the area where we can skip in-loop filtering, in case of cropping.
    //
    // 'Simple' filter reads two luma samples outside of the macroblock
    // and filters one. It doesn't filter the chroma samples. Hence, we can
    // avoid doing the in-loop filtering before crop_top/crop_left position.
    // For the 'Complex' filter, 3 samples are read and up to 3 are filtered.
    // Means: there's a dependency chain that goes all the way up to the
    // top-left corner of the picture (MB #0). We must filter all the previous
    // macroblocks.
    {
      final int extraPixels = _filterExtraRows[_filterType!];
      if (_filterType == 2) {
        // For complex filter, we need to preserve the dependency chain.
        _topLeftMacroblockX = 0;
        _topLeftMacroblockY = 0;
      } else {
        // For simple filter, we can filter only the cropped region.
        // We include 'extra_pixels' on the other side of the boundary, since
        // vertical or horizontal filtering of the previous macroblock can
        // modify some abutting pixels.
        _topLeftMacroblockX = (_cropLeftPixel - extraPixels) ~/ 16;
        _topLeftMacroblockY = (_cropTopPixel! - extraPixels) ~/ 16;
        if (_topLeftMacroblockX < 0) {
          _topLeftMacroblockX = 0;
        }
        if (_topLeftMacroblockY < 0) {
          _topLeftMacroblockY = 0;
        }
      }

      // We need some 'extra' pixels on the right/bottom.
      _bottomRightMacroblockY = (_cropBottomPixel! + 15 + extraPixels) ~/ 16;
      _bottomRightMacroblockX = (_cropRightPixel + 15 + extraPixels) ~/ 16;
      if (_bottomRightMacroblockX! > _macroblockWidth!) {
        _bottomRightMacroblockX = _macroblockWidth;
      }
      if (_bottomRightMacroblockY! > _macroblockHeight!) {
        _bottomRightMacroblockY = _macroblockHeight;
      }
    }

    _macroblockInformation = List<_Vp8MacroBlock>.generate(_macroblockWidth! + 1, (_) => _Vp8MacroBlock(), growable: false);
    _macroblockData = List<_Vp8MacroBlockData>.generate(_macroblockWidth!, (_) => _Vp8MacroBlockData(), growable: false);
    _filterInformation = List<_Vp8FilterInfo?>.filled(_macroblockWidth!, null);

    _precomputeFilterStrengths();

    // Init critical function pointers and look-up tables.
    _filter = _Vp8Filter();
    return true;
  }

  /// Decodes all macroblock rows in presentation order.
    bool _parseFrame() {
    for (_macroblockY = 0; _macroblockY < _bottomRightMacroblockY!; ++_macroblockY) {
      // Parse bitstream for this row.
      final _Vp8BitReader? tokenBr = _partitions[_macroblockY & (_partitionCount - 1)];
      for (; _macroblockX < _macroblockWidth!; ++_macroblockX) {
        if (!_decodeMacroblock(tokenBr)) {
          return false;
        }
      }

      // Prepare for next scanline
      _macroblockInformation[0]
        ..nonZeroCoefficients = 0
        ..nonZeroDirectCurrent = 0;
      _leftIntraModes.fillRange(0, _leftIntraModes.length, _intra4DirectCurrent);
      _macroblockX = 0;

      // Reconstruct, filter and emit the row.
      if (!_processRow()) {
        return false;
      }
    }

    return true;
  }

  /// Reconstructs, filters, and emits the current macroblock row.
    bool _processRow() {
    _reconstructRow();

    final bool useFilter = (_filterType! > 0) && (_macroblockY >= _topLeftMacroblockY) && (_macroblockY <= _bottomRightMacroblockY!);
    return _finishRow(useFilter);
  }

  /// Reconstructs prediction and residual samples for one macroblock row.
    void _reconstructRow() {
    final int mbY = _macroblockY;
    final yDst = _WebPBuffer(data: _sampleBlock, offset: _lumaOffset);
    final uDst = _WebPBuffer(data: _sampleBlock, offset: _blueDifferenceOffset);
    final vDst = _WebPBuffer(data: _sampleBlock, offset: _redDifferenceOffset);

    for (var mbX = 0; mbX < _macroblockWidth!; ++mbX) {
      final _Vp8MacroBlockData block = _macroblockData[mbX];

      // Rotate in the left samples from previously decoded block. We move four
      // pixels at a time for alignment reason, and because of in-loop filter.
      if (mbX > 0) {
        for (var j = -1; j < 16; ++j) {
          yDst.memcpy(j * reconstructionStride - 4, 4, yDst, j * reconstructionStride + 12);
        }

        for (var j = -1; j < 8; ++j) {
          uDst.memcpy(j * reconstructionStride - 4, 4, uDst, j * reconstructionStride + 4);
          vDst.memcpy(j * reconstructionStride - 4, 4, vDst, j * reconstructionStride + 4);
        }
      } else {
        for (var j = 0; j < 16; ++j) {
          yDst[j * reconstructionStride - 1] = 129;
        }

        for (var j = 0; j < 8; ++j) {
          uDst[j * reconstructionStride - 1] = 129;
          vDst[j * reconstructionStride - 1] = 129;
        }

        // Init top-left sample on left column too
        if (mbY > 0) {
          yDst[-1 - reconstructionStride] = uDst[-1 - reconstructionStride] = vDst[-1 - reconstructionStride] = 129;
        }
      }

      // bring top samples into the cache
      final _Vp8TopSamples topYuv = _topSamples[mbX];
      final Int16List coeffs = block.coefficients;
      int? bits = block.nonZeroLuminance;

      if (mbY > 0) {
        yDst.memcpy(-reconstructionStride, 16, topYuv.y);
        uDst.memcpy(-reconstructionStride, 8, topYuv.u);
        vDst.memcpy(-reconstructionStride, 8, topYuv.v);
      } else if (mbX == 0) {
        // we only need to do this init once at block (0,0).
        // Afterward, it remains valid for the whole topmost row.
        yDst.memset(-reconstructionStride - 1, 16 + 4 + 1, 127);
        uDst.memset(-reconstructionStride - 1, 8 + 1, 127);
        vDst.memset(-reconstructionStride - 1, 8 + 1, 127);
      }

      // predict and add residuals
      if (block.isIntra4x4) {
        // 4x4
        final topRight = _WebPBuffer.from(source: yDst, offset: -reconstructionStride + 16);
        final Uint32List topRight32 = topRight.toUint32List();

        if (mbY > 0) {
          if (mbX >= _macroblockWidth! - 1) {
            // on rightmost border
            topRight.memset(0, 4, topYuv.y[15]);
          } else {
            topRight.memcpy(0, 4, _topSamples[mbX + 1].y);
          }
        }

        // replicate the top-right pixels below
        final int p = topRight32[0];
        topRight32[3 * reconstructionStride] = p;
        topRight32[2 * reconstructionStride] = p;
        topRight32[reconstructionStride] = p;

        // predict and add residuals for all 4x4 blocks in turn.
        for (var n = 0; n < 16; ++n, bits = (bits << 2) & 0xffffffff) {
          final dst = _WebPBuffer.from(source: yDst, offset: _blockOffsets[n]);

          _Vp8Filter.luma4Predictors[block.intraModes[n]](dst);

          _inverseTransformLuma(bits!, _WebPBuffer(data: coeffs, offset: n * 16), dst);
        }
      } else {
        // 16x16
        final int predFunc = _validatePredictionMode(mbX, mbY, block.intraModes[0])!;

        _Vp8Filter.luma16Predictors[predFunc](yDst);
        if (bits != 0) {
          for (var n = 0; n < 16; ++n, bits = (bits << 2) & 0xffffffff) {
            final dst = _WebPBuffer.from(source: yDst, offset: _blockOffsets[n]);

            _inverseTransformLuma(bits!, _WebPBuffer(data: coeffs, offset: n * 16), dst);
          }
        }
      }

      // Chroma
      final int bitsUv = block.nonZeroChrominance;
      final int predFunc = _validatePredictionMode(mbX, mbY, block.chrominanceMode)!;
      _Vp8Filter.chroma8Predictors[predFunc](uDst);
      _Vp8Filter.chroma8Predictors[predFunc](vDst);

      final c1 = _WebPBuffer(data: coeffs, offset: 16 * 16);
      _inverseTransformChroma(bitsUv, c1, uDst);

      final c2 = _WebPBuffer(data: coeffs, offset: 20 * 16);
      _inverseTransformChroma(bitsUv >> 8, c2, vDst);

      // stash away top samples for next block
      if (mbY < _macroblockHeight! - 1) {
        topYuv.y.setRange(0, 16, yDst.toUint8List(), 15 * reconstructionStride);
        topYuv.u.setRange(0, 8, uDst.toUint8List(), 7 * reconstructionStride);
        topYuv.v.setRange(0, 8, vDst.toUint8List(), 7 * reconstructionStride);
      }

      // Transfer reconstructed samples from yuv_b_ cache to final destination.
      final int yOut = mbX * 16; // dec->cache_y_ +
      final int uOut = mbX * 8; // dec->cache_u_ +
      final int vOut = mbX * 8; // _dec->cache_v_ +

      for (var j = 0; j < 16; ++j) {
        final int start = yOut + j * _lumaCacheStride!;
        _lumaCache.memcpy(start, 16, yDst, j * reconstructionStride);
      }

      for (var j = 0; j < 8; ++j) {
        int start = uOut + j * _chromaCacheStride!;
        _blueDifferenceCache.memcpy(start, 8, uDst, j * reconstructionStride);

        start = vOut + j * _chromaCacheStride!;
        _redDifferenceCache.memcpy(start, 8, vDst, j * reconstructionStride);
      }
    }
  }

  /// Maps an unavailable-neighbor prediction mode to its valid fallback.
    static int? _validatePredictionMode(int mbX, int mbY, int? mode) {
    if (mode == _intra4DirectCurrent) {
      if (mbX == 0) {
        return (mbY == 0) ? _directCurrentWithoutNeighbors : _directCurrentWithoutLeft;
      } else {
        return (mbY == 0) ? _directCurrentWithoutTop : _intra4DirectCurrent;
      }
    }
    return mode;
  }

  /// Applies the selected inverse transform to luma blocks.
    void _inverseTransformLuma(int bits, _WebPBuffer src, _WebPBuffer dst) {
    switch (bits >> 30) {
      case 3:
        _filter.inverseTransformLumaBlocks(src, dst, false);
        break;
      case 2:
        _filter.inverseTransformSparseBlock(src, dst);
        break;
      case 1:
        _filter.inverseTransformDirectCurrentBlock(src, dst);
        break;
      default:
        break;
    }
  }

  /// Applies the selected inverse transform to chroma blocks.
    void _inverseTransformChroma(int bits, _WebPBuffer src, _WebPBuffer dst) {
    if (bits & 0xff != 0) {
      // any non-zero coeff at all?
      if (bits & 0xaa != 0) {
        // any non-zero AC coefficient?
        // note we don't use the AC3 variant for U/V
        _filter.inverseTransformChromaBlocks(src, dst);
      } else {
        _filter.inverseTransformChromaDirectCurrent(src, dst);
      }
    }
  }

  // vertical position of a MB
  /// Returns the top pixel row of a macroblock row.
    int _macroblockVerticalPosition(int mbY) => mbY * 16;

  /// Applies the configured in-loop filters to one macroblock.
    void _filterMacroblock(int mbX, int mbY) {
    final int? yBps = _lumaCacheStride;
    final _Vp8FilterInfo fInfo = _filterInformation[mbX]!;
    final yDst = _WebPBuffer.from(source: _lumaCache, offset: mbX * 16);
    final int innerLevel = fInfo.innerLevel ?? 0;
    final int limit = fInfo.limit;
    if (limit == 0) {
      return;
    }

    if (_filterType == 1) {
      // simple
      if (mbX > 0) {
        _filter.filterSimpleHorizontalLumaEdge(yDst, yBps!, limit + 4);
      }
      if (fInfo.usesInnerFiltering) {
        _filter.filterSimpleHorizontalLumaInterior(yDst, yBps!, limit);
      }
      if (mbY > 0) {
        _filter.filterSimpleVerticalLumaEdge(yDst, yBps!, limit + 4);
      }
      if (fInfo.usesInnerFiltering) {
        _filter.filterSimpleVerticalLumaInterior(yDst, yBps!, limit);
      }
    } else {
      // complex
      final int? uvBps = _chromaCacheStride;
      final uDst = _WebPBuffer.from(source: _blueDifferenceCache, offset: mbX * 8);
      final vDst = _WebPBuffer.from(source: _redDifferenceCache, offset: mbX * 8);

      final int hevThresh = fInfo.highEdgeVarianceThreshold;
      if (mbX > 0) {
        _filter
          ..filterHorizontalLumaEdge(yDst, yBps!, limit + 4, innerLevel, hevThresh)
          ..filterHorizontalChromaEdge(uDst, vDst, uvBps!, limit + 4, innerLevel, hevThresh);
      }
      if (fInfo.usesInnerFiltering) {
        _filter
          ..filterHorizontalLumaInterior(yDst, yBps!, limit, innerLevel, hevThresh)
          ..filterHorizontalChromaInterior(uDst, vDst, uvBps!, limit, innerLevel, hevThresh);
      }
      if (mbY > 0) {
        _filter
          ..filterVerticalLumaEdge(yDst, yBps!, limit + 4, innerLevel, hevThresh)
          ..filterVerticalChromaEdge(uDst, vDst, uvBps!, limit + 4, innerLevel, hevThresh);
      }
      if (fInfo.usesInnerFiltering) {
        _filter
          ..filterVerticalLumaInterior(yDst, yBps!, limit, innerLevel, hevThresh)
          ..filterVerticalChromaInterior(uDst, vDst, uvBps!, limit, innerLevel, hevThresh);
      }
    }
  }

  // Filter the decoded macroblock row (if needed)
  /// Filters every visible macroblock in the current row.
    void _filterRow() {
    for (int mbX = _topLeftMacroblockX; mbX < _bottomRightMacroblockX!; ++mbX) {
      _filterMacroblock(mbX, _macroblockY);
    }
  }

  // This function is called after a row of macroblocks is finished decoding.
  // It also takes into account the following restrictions:
  //
  // * In case of in-loop filtering, we must hold off sending some of the bottom
  //    pixels as they are yet unfiltered. They will be when the next macroblock
  //    row is decoded. Meanwhile, we must preserve them by rotating them in the
  //    cache area. This doesn't hold for the very bottom row of the uncropped
  //    picture of course.
  //  * we must clip the remaining pixels against the cropping area. The VP8Io
  //   struct must have the following fields set correctly before calling put():
  /// Finalizes filtering and emits all complete output rows.
    bool _finishRow(bool useFilter) {
    final int extraYRows = _filterExtraRows[_filterType!];
    final int ySize = extraYRows * _lumaCacheStride!;
    final int uvSize = (extraYRows ~/ 2) * _chromaCacheStride!;
    final yDst = _WebPBuffer.from(source: _lumaCache, offset: -ySize);
    final uDst = _WebPBuffer.from(source: _blueDifferenceCache, offset: -uvSize);
    final vDst = _WebPBuffer.from(source: _redDifferenceCache, offset: -uvSize);
    final int mbY = _macroblockY;
    final isFirstRow = mbY == 0;
    final bool isLastRow = mbY >= _bottomRightMacroblockY! - 1;
    int? yStart = _macroblockVerticalPosition(mbY);
    int? yEnd = _macroblockVerticalPosition(mbY + 1);

    if (useFilter) {
      _filterRow();
    }

    if (!isFirstRow) {
      yStart -= extraYRows;
      _luma = _WebPBuffer.from(source: yDst);
      _blueDifference = _WebPBuffer.from(source: uDst);
      _redDifference = _WebPBuffer.from(source: vDst);
    } else {
      _luma = _WebPBuffer.from(source: _lumaCache);
      _blueDifference = _WebPBuffer.from(source: _blueDifferenceCache);
      _redDifference = _WebPBuffer.from(source: _redDifferenceCache);
    }

    if (!isLastRow) {
      yEnd -= extraYRows;
    }

    if (yEnd > _cropBottomPixel!) {
      yEnd = _cropBottomPixel; // make sure we don't overflow on last row.
    }

    _alphaRows = null;
    if (_compressedAlpha != null && yStart < yEnd!) {
      _alphaRows = _decodeAlphaRows(yStart, yEnd - yStart);
      if (_alphaRows == null) {
        return false;
      }
    }

    if (yStart < _cropTopPixel!) {
      final int deltaY = _cropTopPixel! - yStart;
      yStart = _cropTopPixel;

      _luma.offset += _lumaCacheStride! * deltaY;
      _blueDifference.offset += _chromaCacheStride! * (deltaY >> 1);
      _redDifference.offset += _chromaCacheStride! * (deltaY >> 1);

      if (_alphaRows != null) {
        _alphaRows!.offset += information.width * deltaY;
      }
    }

    if (yStart! < yEnd!) {
      _luma.offset += _cropLeftPixel;
      _blueDifference.offset += _cropLeftPixel >> 1;
      _redDifference.offset += _cropLeftPixel >> 1;
      if (_alphaRows != null) {
        _alphaRows!.offset += _cropLeftPixel;
      }

      _writeOutputRows(yStart - _cropTopPixel!, _cropRightPixel - _cropLeftPixel, yEnd - yStart);
    }

    // rotate top samples if needed
    if (!isLastRow) {
      _lumaCache.memcpy(-ySize, ySize, yDst, 16 * _lumaCacheStride!);
      _blueDifferenceCache.memcpy(-uvSize, uvSize, uDst, 8 * _chromaCacheStride!);
      _redDifferenceCache.memcpy(-uvSize, uvSize, vDst, 8 * _chromaCacheStride!);
    }

    return true;
  }

  /// Converts and writes a group of reconstructed output rows.
    bool _writeOutputRows(int mbY, int mbW, int mbH) {
    if (mbW <= 0 || mbH <= 0) {
      return false;
    }

    /*int numLinesOut = */
    _writeUpsampledRgb(mbY, mbW, mbH);
    _writeAlpha(mbY, mbW, mbH);

    //_lastY += numLinesOut;

    return true;
  }

  /// Clips a fixed-point color value to an unsigned byte.
    int _clipColorSample(int v) {
    final int d = ((v & _inverseColorConversionMask) == 0)
        ? (v >> _colorConversionFractionBits)
        : (v < 0)
        ? 0
        : 255;
    return d;
  }

  /// Converts one YUV sample to red.
    int _yuvToR(int y, int v) => _clipColorSample(_lumaScale * y + _redDifferenceToRed * v + _redConversionOffset);

  /// Converts one YUV sample to green.
    int _yuvToG(int y, int u, int v) => _clipColorSample(_lumaScale * y - _blueDifferenceToGreen * u - _redDifferenceToGreen * v + _greenConversionOffset);

  /// Converts one YUV sample to blue.
    int _yuvToB(int y, int u) => _clipColorSample(_lumaScale * y + _blueDifferenceToBlue * u + _blueConversionOffset);

  /// Writes one opaque RGB pixel from YUV samples.
    void _yuvToRgb(int y, int u, int v, _WebPBuffer rgb) {
    rgb[0] = _yuvToR(y, v);
    rgb[1] = _yuvToG(y, u, v);
    rgb[2] = _yuvToB(y, u);
  }

  /// Writes one RGBA pixel from YUV samples and decoded alpha.
    void _yuvToRgba(int y, int u, int v, _WebPBuffer rgba) {
    _yuvToRgb(y, u, v, rgba);
    rgba[3] = 0xff;
  }

  /// Upsamples adjacent chroma rows while converting them to RGB.
    void _upsample(_WebPBuffer topY, _WebPBuffer? bottomY, _WebPBuffer topU, _WebPBuffer topV, _WebPBuffer curU, _WebPBuffer curV, _WebPBuffer topDst, _WebPBuffer? bottomDst, int len) {
    int loadUv(int u, int v) => u | (v << 16);

    final int lastPixelPair = (len - 1) >> 1;
    int tlUv = loadUv(topU[0], topV[0]); // top-left sample
    int lUv = loadUv(curU[0], curV[0]); // left-sample

    final int uv0 = (3 * tlUv + lUv + 0x00020002) >> 2;
    _yuvToRgba(topY[0], uv0 & 0xff, uv0 >> 16, topDst);

    if (bottomY != null) {
      final int uv0 = (3 * lUv + tlUv + 0x00020002) >> 2;
      _yuvToRgba(bottomY[0], uv0 & 0xff, uv0 >> 16, bottomDst!);
    }

    for (var x = 1; x <= lastPixelPair; ++x) {
      final int tUv = loadUv(topU[x], topV[x]); // top sample
      final int uv = loadUv(curU[x], curV[x]); // sample
      // precompute invariant values associated with first and second diagonals
      final int avg = tlUv + tUv + lUv + uv + 0x00080008;
      final int diag12 = (avg + 2 * (tUv + lUv)) >> 3;
      final int diag03 = (avg + 2 * (tlUv + uv)) >> 3;

      int uv0 = (diag12 + tlUv) >> 1;
      int uv1 = (diag03 + tUv) >> 1;

      _yuvToRgba(topY[2 * x - 1], uv0 & 0xff, uv0 >> 16, _WebPBuffer.from(source: topDst, offset: (2 * x - 1) * 4));

      _yuvToRgba(topY[2 * x - 0], uv1 & 0xff, uv1 >> 16, _WebPBuffer.from(source: topDst, offset: (2 * x - 0) * 4));

      if (bottomY != null) {
        uv0 = (diag03 + lUv) >> 1;
        uv1 = (diag12 + uv) >> 1;

        _yuvToRgba(bottomY[2 * x - 1], uv0 & 0xff, uv0 >> 16, _WebPBuffer.from(source: bottomDst!, offset: (2 * x - 1) * 4));

        _yuvToRgba(bottomY[2 * x], uv1 & 0xff, uv1 >> 16, _WebPBuffer.from(source: bottomDst, offset: (2 * x + 0) * 4));
      }

      tlUv = tUv;
      lUv = uv;
    }

    if ((len & 1) == 0) {
      final int uv0 = (3 * tlUv + lUv + 0x00020002) >> 2;
      _yuvToRgba(topY[len - 1], uv0 & 0xff, uv0 >> 16, _WebPBuffer.from(source: topDst, offset: (len - 1) * 4));

      if (bottomY != null) {
        final int uv0 = (3 * lUv + tlUv + 0x00020002) >> 2;
        _yuvToRgba(bottomY[len - 1], uv0 & 0xff, uv0 >> 16, _WebPBuffer.from(source: bottomDst!, offset: (len - 1) * 4));
      }
    }
  }

  /// Copies decoded alpha values into the output image.
    void _writeAlpha(int mbY, int mbW, int mbH) {
    if (_alphaRows == null) {
      return;
    }

    final alpha = _WebPBuffer.from(source: _alphaRows!);
    var startY = mbY;
    var numRows = mbH;

    // Compensate for the 1-line delay of the fancy upscaler.
    // This is similar to EmitFancyRGB().
    if (startY == 0) {
      // We don't process the last row yet. It'll be done during the next call.
      --numRows;
    } else {
      --startY;
      // Fortunately, *alpha data is persistent, so we can go back
      // one row and finish alpha blending, now that the fancy upscaler
      // completed the YUV->RGB interpolation.
      alpha.offset -= information.width;
    }

    //final dst = _WebPBuffer(data: _output!.getBytes(), offset: startY * stride + 3);

    if (_cropTopPixel! + mbY + mbH == _cropBottomPixel) {
      // If it's the very last call, we process all the remaining rows!
      numRows = _cropBottomPixel! - _cropTopPixel! - startY;
    }

    for (var y = 0; y < numRows; ++y) {
      for (var x = 0; x < mbW; ++x) {
        final int alphaValue = alpha[x];
        _output!.bytes[((y + startY) * information.width + x) * 4 + 3] = alphaValue;
      }

      alpha.offset += information.width;
    }
  }

  /// Converts reconstructed YUV rows to interleaved RGBA.
    int _writeUpsampledRgb(int mbY, int mbW, int mbH) {
    var numLinesOut = mbH; // a priori guess
    final Uint8List outputBytes = _output!.bytes;
    final dst = _WebPBuffer(data: outputBytes, offset: mbY * information.width * 4);
    final curY = _WebPBuffer.from(source: _luma);
    final curU = _WebPBuffer.from(source: _blueDifference);
    final curV = _WebPBuffer.from(source: _redDifference);
    var y = mbY;
    final int yEnd = mbY + mbH;
    final int uvW = (mbW + 1) >> 1;
    final int stride = information.width * 4;
    final topU = _WebPBuffer.from(source: _temporaryBlueDifference);
    final topV = _WebPBuffer.from(source: _temporaryRedDifference);

    if (y == 0) {
      // First line is special cased. We mirror the u/v samples at boundary.
      _upsample(curY, null, curU, curV, curU, curV, dst, null, mbW);
    } else {
      // We can finish the left-over line from previous call.
      _upsample(_temporaryLuma, curY, topU, topV, curU, curV, _WebPBuffer.from(source: dst, offset: -stride), dst, mbW);
      ++numLinesOut;
    }

    // Loop over each _output pairs of row.
    topU.buffer = curU.buffer;
    topV.buffer = curV.buffer;
    for (; y + 2 < yEnd; y += 2) {
      topU.offset = curU.offset;
      topV.offset = curV.offset;
      curU.offset += _chromaCacheStride!;
      curV.offset += _chromaCacheStride!;
      dst.offset += 2 * stride;
      curY.offset += 2 * _lumaCacheStride!;
      _upsample(_WebPBuffer.from(source: curY, offset: -_lumaCacheStride!), curY, topU, topV, curU, curV, _WebPBuffer.from(source: dst, offset: -stride), dst, mbW);
    }

    // move to last row
    curY.offset += _lumaCacheStride!;
    if (_cropTopPixel! + yEnd < _cropBottomPixel!) {
      // Save the unfinished samples for next call (as we're not done yet).
      _temporaryLuma.memcpy(0, mbW, curY);
      _temporaryBlueDifference.memcpy(0, uvW, curU);
      _temporaryRedDifference.memcpy(0, uvW, curV);
      // The fancy upsampler leaves a row unfinished behind
      // (except for the very last row)
      numLinesOut--;
    } else {
      // Process the very last row of even-sized picture
      if ((yEnd & 1) == 0) {
        _upsample(curY, null, curU, curV, curU, curV, _WebPBuffer.from(source: dst, offset: stride), null, mbW);
      }
    }

    return numLinesOut;
  }

  /// Decodes and returns the requested alpha rows.
    _WebPBuffer? _decodeAlphaRows(int row, int numRows) {
    final int width = information.width;
    final int height = information.height;

    if (row < 0 || numRows <= 0 || row + numRows > height) {
      return null; // sanity check.
    }

    if (row == 0) {
      _decodedAlpha = Uint8List(width * height);
      _alphaDecoder = _WebPAlphaDecoder(
        input: _compressedAlpha!,
        width: width,
        height: height,
      );
    }

    if (!_alphaDecoder.isDecoded) {
      if (!_alphaDecoder.decode(row, numRows, _decodedAlpha)) {
        return null;
      }
    }

    // Return a pointer to the current decoded row.
    return _WebPBuffer(data: _decodedAlpha, offset: row * width);
  }

  /// Decodes prediction modes and residuals for one macroblock.
    bool _decodeMacroblock(_Vp8BitReader? tokenBr) {
    final _Vp8MacroBlock left = _macroblockInformation[0];
    final _Vp8MacroBlock mb = _macroblockInformation[1 + _macroblockX];
    final _Vp8MacroBlockData block = _macroblockData[_macroblockX];
    bool skip;

    // Note: we don't save segment map (yet), as we don't expect
    // to decode more than 1 keyframe.
    if (_segmentHeader.updatesMap) {
      // Hardcoded tree parsing
      _segmentIndex = bitReader.readBit(_probabilities!.segmentProbabilities[0]) == 0
          ? bitReader.readBit(_probabilities!.segmentProbabilities[1])
          : 2 + bitReader.readBit(_probabilities!.segmentProbabilities[2]);
    }

    skip = _usesSkipProbability && bitReader.readBit(_skipProbability) != 0;

    _parseIntraPredictionModes();

    if (!skip) {
      skip = _parseResiduals(mb, tokenBr);
    } else {
      left.nonZeroCoefficients = mb.nonZeroCoefficients = 0;
      if (!block.isIntra4x4) {
        left.nonZeroDirectCurrent = mb.nonZeroDirectCurrent = 0;
      }
      block
        ..nonZeroLuminance = 0
        ..nonZeroChrominance = 0;
    }

    if (_filterType! > 0) {
      // store filter info
      _filterInformation[_macroblockX] = _filterStrengths[_segmentIndex][block.isIntra4x4 ? 1 : 0];
      final _Vp8FilterInfo finfo = _filterInformation[_macroblockX]!;
      finfo.usesInnerFiltering = finfo.usesInnerFiltering || !skip;
    }

    return true;
  }

  /// Reads quantized residual coefficients for one macroblock.
    bool _parseResiduals(_Vp8MacroBlock mb, _Vp8BitReader? tokenBr) {
    final List<List<_Vp8BandProbabilities>> bands = _probabilities!.bandProbabilities;
    List<_Vp8BandProbabilities> acProba;
    final _Vp8QuantizationMatrix? q = _quantizationMatrices[_segmentIndex];
    final _Vp8MacroBlockData block = _macroblockData[_macroblockX];
    final dst = _WebPBuffer(data: block.coefficients);
    //int di = 0;
    final _Vp8MacroBlock leftMb = _macroblockInformation[0];
    int tnz;
    int lnz;
    var nonZeroY = 0;
    var nonZeroUV = 0;
    int outTopNz;
    int outLeftNz;
    int first;

    dst.memset(0, dst.length, 0);

    if (!block.isIntra4x4) {
      // parse DC
      final dc = _WebPBuffer(data: Int16List(16));
      final int ctx = mb.nonZeroDirectCurrent + leftMb.nonZeroDirectCurrent;
      final int nz = _readCoefficients(tokenBr, bands[1], ctx, q!.directCurrentMatrix, 0, dc);
      mb.nonZeroDirectCurrent = leftMb.nonZeroDirectCurrent = (nz > 0) ? 1 : 0;
      if (nz > 1) {
        // more than just the DC -> perform the full inverseTransformLumaBlocks
        _inverseWalshHadamardTransform(dc, dst);
      } else {
        // only DC is non-zero -> inlined simplified inverseTransformLumaBlocks
        final int dc0 = (dc[0] + 3) >> 3;
        for (var i = 0; i < 16 * 16; i += 16) {
          dst[i] = dc0;
        }
      }

      first = 1;
      acProba = bands[0];
    } else {
      first = 0;
      acProba = bands[3];
    }

    tnz = mb.nonZeroCoefficients & 0x0f;
    lnz = leftMb.nonZeroCoefficients & 0x0f;
    for (var y = 0; y < 4; ++y) {
      int l = lnz & 1;
      var nzCoeffs = 0;
      for (var x = 0; x < 4; ++x) {
        final int ctx = l + (tnz & 1);
        final int nz = _readCoefficients(tokenBr, acProba, ctx, q!.luminanceMatrix, first, dst);
        l = (nz > first) ? 1 : 0;
        tnz = (tnz >> 1) | (l << 7);
        nzCoeffs = _nonZeroContext(nzCoeffs, nz, dst[0] != 0 ? 1 : 0);
        dst.offset += 16;
      }

      tnz >>= 4;
      lnz = (lnz >> 1) | (l << 7);
      nonZeroY = (nonZeroY << 8) | nzCoeffs;
    }
    outTopNz = tnz;
    outLeftNz = lnz >> 4;

    for (var ch = 0; ch < 4; ch += 2) {
      var nzCoeffs = 0;
      tnz = mb.nonZeroCoefficients >> (4 + ch);
      lnz = leftMb.nonZeroCoefficients >> (4 + ch);
      for (var y = 0; y < 2; ++y) {
        int l = lnz & 1;
        for (var x = 0; x < 2; ++x) {
          final int ctx = l + (tnz & 1);
          final int nz = _readCoefficients(tokenBr, bands[2], ctx, q!.chrominanceMatrix, 0, dst);
          l = (nz > 0) ? 1 : 0;
          tnz = (tnz >> 1) | (l << 3);
          nzCoeffs = _nonZeroContext(nzCoeffs, nz, dst[0] != 0 ? 1 : 0);
          dst.offset += 16;
        }

        tnz >>= 2;
        lnz = (lnz >> 1) | (l << 5);
      }

      // Note: we don't really need the per-4x4 details for U/V blocks.
      nonZeroUV |= nzCoeffs << (4 * ch);
      outTopNz |= (tnz << 4) << ch;
      outLeftNz |= (lnz & 0xf0) << ch;
    }

    mb.nonZeroCoefficients = outTopNz;
    leftMb.nonZeroCoefficients = outLeftNz;

    block
      ..nonZeroLuminance = nonZeroY
      ..nonZeroChrominance = nonZeroUV
      // We look at the mode-code of each block and check if some blocks have
      // less than three non-zero coeffs (code < 2). This is to avoid dithering
      // flat and empty blocks.
      ..dithering = (nonZeroUV & 0xaaaa) != 0 ? 0 : q!.dithering;

    // will be used for further optimization
    return (nonZeroY | nonZeroUV) == 0;
  }

  /// Applies the inverse Walsh-Hadamard transform to luma DC coefficients.
    void _inverseWalshHadamardTransform(_WebPBuffer src, _WebPBuffer out) {
    final tmp = Int32List(16);

    var oi = 0;
    for (var i = 0; i < 4; ++i) {
      final int a0 = src[0 + i] + src[12 + i];
      final int a1 = src[4 + i] + src[8 + i];
      final int a2 = src[4 + i] - src[8 + i];
      final int a3 = src[0 + i] - src[12 + i];
      tmp[0 + i] = a0 + a1;
      tmp[8 + i] = a0 - a1;
      tmp[4 + i] = a3 + a2;
      tmp[12 + i] = a3 - a2;
    }

    for (var i = 0; i < 4; ++i) {
      final int dc = tmp[0 + i * 4] + 3; // w/ rounder
      final int a0 = dc + tmp[3 + i * 4];
      final int a1 = tmp[1 + i * 4] + tmp[2 + i * 4];
      final int a2 = tmp[1 + i * 4] - tmp[2 + i * 4];
      final int a3 = dc - tmp[3 + i * 4];
      out[oi + 0] = (a0 + a1) >> 3;
      out[oi + 16] = (a3 + a2) >> 3;
      out[oi + 32] = (a0 - a1) >> 3;
      out[oi + 48] = (a3 - a2) >> 3;

      oi += 64;
    }
  }

  /// Packs neighboring nonzero flags into a coefficient context.
    int _nonZeroContext(int nzCoeffs, int nz, int dcNz) {
    int result = nzCoeffs << 2;
    result |= (nz > 3)
        ? 3
        : (nz > 1)
        ? 2
        : dcNz;
    return result;
  }

  // See section 13-2: http://tools.ietf.org/html/rfc6386#section-13.2
  /// Reads a coefficient magnitude greater than one.
    int _readLargeCoefficient(_Vp8BitReader bitReader, List<int> p) {
    int v;
    if (bitReader.readBit(p[3]) == 0) {
      if (bitReader.readBit(p[4]) == 0) {
        v = 2;
      } else {
        v = 3 + bitReader.readBit(p[5]);
      }
    } else {
      if (bitReader.readBit(p[6]) == 0) {
        if (bitReader.readBit(p[7]) == 0) {
          v = 5 + bitReader.readBit(159);
        } else {
          v = 7 + 2 * bitReader.readBit(165);
          v += bitReader.readBit(145);
        }
      } else {
        final int bit1 = bitReader.readBit(p[8]);
        final int bit0 = bitReader.readBit(p[9 + bit1]);
        final int cat = 2 * bit1 + bit0;
        v = 0;
        final List<int> tab = _largeCoefficientProbabilities[cat];
        final int len = tab.length;
        for (var i = 0; i < len; ++i) {
          v += v + bitReader.readBit(tab[i]);
        }
        v += 3 + (8 << cat);
      }
    }
    return v;
  }

  // Returns the position of the last non-zero coeff plus one
  /// Reads, dequantizes, and reorders one transform block.
    int _readCoefficients(_Vp8BitReader? bitReader, List<_Vp8BandProbabilities> prob, int ctx, List<int> dq, int n, _WebPBuffer out) {
    // n is either 0 or 1 here. _coefficientBands[n] is not necessary for extracting '*p'.
    int coefficient = n;
    List<int> p = prob[coefficient].probabilities[ctx];
    for (; coefficient < 16; ++coefficient) {
      if (bitReader!.readBit(p[0]) == 0) {
        return coefficient; // previous coeff was last non-zero coeff
      }

      while (bitReader.readBit(p[1]) == 0) {
        // sequence of zero coeffs
        p = prob[_coefficientBands[++coefficient]].probabilities[0];
        if (coefficient == 16) {
          return 16;
        }
      }

      {
        // non zero coeff
        final List<Uint8List> pCtx = prob[_coefficientBands[coefficient + 1]].probabilities;
        int v;
        if (bitReader.readBit(p[2]) == 0) {
          v = 1;
          p = pCtx[1];
        } else {
          v = _readLargeCoefficient(bitReader, p);
          p = pCtx[2];
        }

        out[_zigzagOrder[coefficient]] = bitReader.readSignedValue(v) * dq[coefficient > 0 ? 1 : 0];
      }
    }
    return 16;
  }

  /// Reads luma and chroma intra-prediction modes.
    void _parseIntraPredictionModes() {
    final int ti = 4 * _macroblockX;
    const li = 0;
    final Uint8List? top = _topIntraModes;
    final Uint8List left = _leftIntraModes;

    final _Vp8MacroBlockData block = _macroblockData[_macroblockX]
      // decide for B_PRED first
      ..isIntra4x4 = bitReader.readBit(145) == 0;

    if (!block.isIntra4x4) {
      // Hardcoded 16x16 intra-mode decision tree.
      final int ymode = bitReader.readBit(156) != 0
          ? (bitReader.readBit(128) != 0 ? _trueMotionPrediction : _horizontalPrediction)
          : (bitReader.readBit(163) != 0 ? _verticalPrediction : _directCurrentPrediction);
      block.intraModes[0] = ymode;

      top!.fillRange(ti, ti + 4, ymode);
      left.fillRange(li, li + 4, ymode);
    } else {
      final Uint8List modes = block.intraModes;
      var mi = 0;
      for (var y = 0; y < 4; ++y) {
        int ymode = left[y];
        for (var x = 0; x < 4; ++x) {
          final List<int> prob = _intra4ModeProbabilities[top![ti + x]][ymode];

          // Generic tree-parsing
          final int b = bitReader.readBit(prob[0]);
          int i = _intra4ModeTree[b];

          while (i > 0) {
            i = _intra4ModeTree[2 * i + bitReader.readBit(prob[i])];
          }

          ymode = -i;
          top[ti + x] = ymode;
        }

        modes.setRange(mi, mi + 4, top!, ti);

        mi += 4;
        left[y] = ymode;
      }
    }

    // Hardcoded UVMode decision tree
    block.chrominanceMode = bitReader.readBit(142) == 0
        ? _directCurrentPrediction
        : bitReader.readBit(114) == 0
        ? _verticalPrediction
        : bitReader.readBit(183) != 0
        ? _trueMotionPrediction
        : _horizontalPrediction;
  }

  /// Clamps a value to the inclusive range from zero to a maximum.
    static int _clamp(int v, int M) => v < 0
      ? 0
      : v > M
      ? M
      : v;
}
