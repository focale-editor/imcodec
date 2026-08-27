part of '../jpeg.dart';

/// Number of coefficients in one JPEG discrete-cosine-transform block.
const int jpegDctBlockCoefficientCount = 64;

/// Maximum bit length accepted by a JPEG Huffman table.
const int jpegHuffmanMaximumBitLength = 16;

/// Number of symbols addressable by a JPEG Huffman table.
const int jpegHuffmanAlphabetSize = 256;

/// Number of magnitude categories in the JPEG DC alphabet.
const int jpegDcAlphabetSize = 12;

/// Maps zigzag scan positions to natural row-major coefficient positions.
const List<int> jpegZigZagToNaturalOrder = [
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, //
  27, 20, 13, 6, 7, 14, 21, 28, //
  35, 42, 49, 56, 57, 50, 43, 36, //
  29, 22, 15, 23, 30, 37, 44, 51, //
  58, 59, 52, 45, 38, 31, 39, 46, //
  53, 60, 61, 54, 47, 55, 62, 63, //
];

/// Maps natural row-major coefficient positions to zigzag scan positions.
const List<int> jpegNaturalToZigZagOrder = [
  0, 1, 5, 6, 14, 15, 27, 28, //
  2, 4, 7, 13, 16, 26, 29, 42, //
  3, 8, 12, 17, 25, 30, 41, 43, //
  9, 11, 18, 24, 31, 40, 44, 53, //
  10, 19, 23, 32, 39, 45, 52, 54, //
  20, 22, 33, 38, 46, 51, 55, 60, //
  21, 34, 37, 47, 50, 56, 59, 61, //
  35, 36, 48, 49, 57, 58, 62, 63, //
];

/// Maps a potentially overrun progressive index to a safe natural position.
/// The extra entries preserve the established decoder behavior while a scan
/// validates its final run length.
const List<int> jpegZigZagToNaturalOrderWithPadding = [
  ...jpegZigZagToNaturalOrder,
  63, 63, 63, 63, 63, 63, 63, 63, //
  63, 63, 63, 63, 63, 63, 63, 63, //
];

/// Defines marker-byte values shared by JPEG parsing and reconstruction.
abstract final class JpegMarker {
  /// Baseline discrete-cosine frame.
  static const int startOfFrameBaseline = 0xc0;

  /// Extended sequential discrete-cosine frame.
  static const int startOfFrameExtended = 0xc1;

  /// Progressive discrete-cosine frame.
  static const int startOfFrameProgressive = 0xc2;

  /// Lossless Huffman frame.
  static const int startOfFrameLossless = 0xc3;

  /// Huffman-table definition.
  static const int defineHuffmanTable = 0xc4;

  /// Differential sequential Huffman frame.
  static const int startOfFrameDifferentialSequential = 0xc5;

  /// Differential progressive Huffman frame.
  static const int startOfFrameDifferentialProgressive = 0xc6;

  /// Differential lossless Huffman frame.
  static const int startOfFrameDifferentialLossless = 0xc7;

  /// Extended sequential arithmetic frame.
  static const int startOfFrameArithmeticExtended = 0xc9;

  /// Progressive arithmetic frame.
  static const int startOfFrameArithmeticProgressive = 0xca;

  /// Lossless arithmetic frame.
  static const int startOfFrameArithmeticLossless = 0xcb;

  /// Differential sequential arithmetic frame.
  static const int startOfFrameArithmeticDifferentialSequential = 0xcd;

  /// Differential progressive arithmetic frame.
  static const int startOfFrameArithmeticDifferentialProgressive = 0xce;

  /// Differential lossless arithmetic frame.
  static const int startOfFrameArithmeticDifferentialLossless = 0xcf;

  /// First restart marker.
  static const int restart0 = 0xd0;

  /// Last restart marker.
  static const int restart7 = 0xd7;

  /// Start-of-image marker.
  static const int startOfImage = 0xd8;

  /// End-of-image marker.
  static const int endOfImage = 0xd9;

  /// Start-of-scan marker.
  static const int startOfScan = 0xda;

  /// Quantization-table definition.
  static const int defineQuantizationTable = 0xdb;

  /// Restart-interval definition.
  static const int defineRestartInterval = 0xdd;

  /// First application-specific marker.
  static const int application0 = 0xe0;

  /// Exif application marker.
  static const int application1 = 0xe1;

  /// Adobe application marker.
  static const int application14 = 0xee;

  /// Last application-specific marker.
  static const int application15 = 0xef;

  /// Comment marker.
  static const int comment = 0xfe;
}

/// Stores canonical Huffman codes indexed by JPEG symbol.
final class JpegHuffmanCodeTable {
  /// Bit length assigned to each symbol.
  final Uint8List bitLengths = Uint8List(jpegHuffmanAlphabetSize);

  /// Canonical code assigned to each symbol.
  final Int32List codes = Int32List(jpegHuffmanAlphabetSize);

  /// Creates an empty code table ready for [populate].
  JpegHuffmanCodeTable();

  /// Creates and populates a code table from a JPEG definition.
  factory JpegHuffmanCodeTable.fromDefinition({
    required List<int> countsByBitLength,
    required List<int> symbols,
  }) {
    final JpegHuffmanCodeTable table = JpegHuffmanCodeTable();
    table.populate(countsByBitLength: countsByBitLength, symbols: symbols);
    return table;
  }

  /// Populates canonical codes from bit-length counts and ordered [symbols].
  /// Symbols outside the JPEG alphabet are ignored after contributing to the
  /// canonical-code sequence; JPEG XL reconstruction uses this for its
  /// synthetic end-of-information sentinel.
  void populate({
    required List<int> countsByBitLength,
    required List<int> symbols,
  }) {
    bitLengths.fillRange(0, bitLengths.length, 0);
    codes.fillRange(0, codes.length, 0);
    int code = 0;
    int symbolPosition = 0;
    for (int bitLength = 1; bitLength <= jpegHuffmanMaximumBitLength; bitLength++) {
      final int codeCount = countsByBitLength[bitLength];
      for (int codeIndex = 0; codeIndex < codeCount; codeIndex++) {
        final int symbol = symbols[symbolPosition++];
        if (symbol >= 0 && symbol < jpegHuffmanAlphabetSize) {
          bitLengths[symbol] = bitLength;
          codes[symbol] = code;
        }
        code++;
      }
      code <<= 1;
    }
  }
}

/// Returns the JPEG magnitude-category width of [value].
int jpegMagnitudeBitCount(int value) {
  int absoluteValue = value < 0 ? -value : value;
  int bitCount = 0;
  while (absoluteValue > 0) {
    bitCount++;
    absoluteValue >>= 1;
  }
  return bitCount;
}

/// Returns the JPEG magnitude payload for [value].
/// Negative values use JPEG's one's-complement representation.
int jpegMagnitudeValue(int value, int bitCount) => (value >= 0 ? value : value - 1) & ((1 << bitCount) - 1);
