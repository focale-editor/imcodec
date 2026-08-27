// In-memory model of a JPEG file's non-pixel structure, as carried by a
// JPEG XL `jbrd` (JPEG bitstream reconstruction data) box plus the quantized
// DCT coefficients recovered from the codestream. Ported from libjxl's
// `lib/jxl/jpeg/jpeg_data.h`; used to re-emit the exact original JPEG bytes.
//
// Only the fields needed for reconstruction are modelled. Quant-table values
// and the DCT coefficients are NOT in the jbrd box — they live in the JXL
// codestream and are filled in from the decode.

import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg.dart';

/// Identifies specialized payloads carried by JPEG application markers.
/// [unknown] markers store their bytes verbatim in the `jbrd` Brotli tail;
/// specialized payloads are reconstructed from their corresponding boxes.
enum JpegApplicationMarkerType {
  /// Stores a marker whose payload has no specialized representation.
  unknown,

  /// Stores an ICC color-profile marker.
  icc,

  /// Stores an Exif metadata marker.
  exif,

  /// Stores an XMP metadata marker.
  xmp,
}

/// Stores one JPEG quantization table in natural coefficient order.
/// [values] come from the JPEG XL codestream rather than the `jbrd` box.
final class JpegQuantizationTable {
  /// Quantization values in natural row-major coefficient order.
  Int32List values = Int32List(jpegDctBlockCoefficientCount);

  /// Zero for 8-bit values or one for 16-bit values.
  int precision = 0;

  /// Destination-table identifier written into the DQT marker.
  int index = 0;

  /// Whether this table ends the current reconstructed DQT segment.
  bool isLast = true;

  /// Creates an empty quantization table for incremental reconstruction.
  JpegQuantizationTable();
}

/// Stores one JPEG Huffman-table definition.
/// [counts] is the bit-length histogram with entry zero unused, while [values]
/// contains symbols sorted by increasing code length. [slotIdentifier] packs
/// the table class in bit four and the table identifier in the low nibble.
final class JpegHuffmanTable {
  /// Number of codes at each bit length; entry zero is unused.
  Uint32List counts = Uint32List(jpegHuffmanMaximumBitLength + 1);

  /// Symbols ordered first by code length and then by canonical code.
  Uint32List values = Uint32List(jpegHuffmanAlphabetSize + 1);

  /// Packed table class and identifier written into the DHT marker.
  /// Bit four selects AC data and the low nibble selects the table slot.
  int slotIdentifier = 0;

  /// Whether this table ends the current reconstructed DHT segment.
  bool isLast = true;

  /// Creates an empty Huffman table for incremental reconstruction.
  JpegHuffmanTable();
}

/// Per-component Huffman table selection within one scan.
final class JpegScanComponent {
  /// Index of the JPEG component included in the scan.
  int componentIndex = 0;

  /// DC Huffman-table index selected for the component.
  int dcTableIndex = 0;

  /// AC Huffman-table index selected for the component.
  int acTableIndex = 0;

  /// Creates a scan-component entry with baseline defaults.
  JpegScanComponent();
}

/// Stores the component and spectral parameters of one JPEG scan.
/// Baseline scans use `0`, `63`, `0`, and `0` for their spectral and
/// successive-approximation fields.
final class JpegScan {
  /// First coefficient index included by spectral selection.
  int spectralStart = 0;

  /// Last coefficient index included by spectral selection.
  int spectralEnd = 63;

  /// Previous bit position refined by a progressive scan.
  int successiveApproximationHigh = 0;

  /// Bit position transmitted by a progressive scan.
  int successiveApproximationLow = 0;

  /// Number of entries from [components] included in this scan.
  int componentCount = 0;

  /// Fixed-capacity component entries referenced by [componentCount].
  final List<JpegScanComponent> components = List.generate(4, (_) => JpegScanComponent(), growable: false);

  /// Last JPEG XL pass required before this scan can be reconstructed.
  int finalRequiredPass = 0;

  /// Block indices where end-of-band runs / refinement bits must be flushed.
  Uint32List resetPoints = Uint32List(0);

  /// Extra zero-run-length codes emitted before selected block endings.
  List<({int blockIndex, int extraZeroRunCount})> extraZeroRuns = const [];

  /// Creates an empty scan with baseline spectral defaults.
  JpegScan();
}

/// Stores one JPEG component and its recovered quantized coefficients.
/// Coefficients are grouped by block in natural 8 × 8 order.
final class JpegComponent {
  /// Component identifier written into SOF and SOS markers.
  int identifier = 0;

  /// Horizontal sampling factor relative to the maximum component factor.
  int horizontalSamplingFactor = 1;

  /// Vertical sampling factor relative to the maximum component factor.
  int verticalSamplingFactor = 1;

  /// Index of the quantization table used by this component.
  int quantizationTableIndex = 0;

  /// Width of the coefficient plane in 8 × 8 blocks.
  int widthInBlocks = 0;

  /// Height of the coefficient plane in 8 × 8 blocks.
  int heightInBlocks = 0;

  /// `coefficients[(blockY * widthInBlocks + blockX) * 64 + naturalPos]`.
  Int32List coefficients = Int32List(0);

  /// Creates an empty component with unit sampling factors.
  JpegComponent();
}

/// Combines reconstructed JPEG structure with recovered coefficients.
/// This is the complete in-memory input consumed by [writeJpeg].
final class JpegReconstructionData {
  /// Reconstructed image width in pixels.
  int width = 0;

  /// Reconstructed image height in pixels.
  int height = 0;

  /// Restart interval measured in minimum coded units.
  int restartInterval = 0;

  /// Complete application-marker bodies without their leading `0xFF` byte.
  List<Uint8List> applicationMarkerData = [];

  /// Specialized payload kind associated with each application marker.
  List<JpegApplicationMarkerType> applicationMarkerTypes = [];

  /// Complete reconstructed COM marker bodies without the leading `0xFF`.
  List<Uint8List> commentMarkerData = [];

  /// Quantization tables recovered from the JPEG XL codestream.
  List<JpegQuantizationTable> quantizationTables = [];

  /// Huffman tables declared by the reconstruction-data box.
  List<JpegHuffmanTable> huffmanTables = [];

  /// Frame components and their recovered coefficient planes.
  List<JpegComponent> components = [];

  /// Entropy-coded scans in marker order.
  List<JpegScan> scans = [];

  /// Marker order without `0xFF` prefixes.
  /// A `0xFF` entry acts as a sentinel for payloads in [interMarkerData].
  Uint8List markerOrder = Uint8List(0);

  /// Raw bytes represented by `0xFF` sentinels in [markerOrder].
  List<Uint8List> interMarkerData = [];

  /// Bytes following the final reconstructed JPEG marker.
  Uint8List trailingData = Uint8List(0);

  /// Whether [entropyPaddingBits] must replace the usual all-one padding.
  bool preservesZeroPaddingBits = false;

  /// One bit per entry (0/1); the exact entropy-segment padding bits.
  Uint8List entropyPaddingBits = Uint8List(0);

  /// Creates empty mutable state populated by the reconstruction decoder.
  JpegReconstructionData();
}
