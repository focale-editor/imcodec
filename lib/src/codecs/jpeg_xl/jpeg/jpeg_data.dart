// In-memory model of a JPEG file's non-pixel structure, as carried by a
// JPEG XL `jbrd` (JPEG bitstream reconstruction data) box plus the quantized
// DCT coefficients recovered from the codestream. Ported from libjxl's
// `lib/jxl/jpeg/jpeg_data.h`; used to re-emit the exact original JPEG bytes.
//
// Only the fields needed for reconstruction are modelled. Quant-table values
// and the DCT coefficients are NOT in the jbrd box — they live in the JXL
// codestream and are filled in from the decode.

import 'dart:typed_data';

/// Maps a JPEG zig-zag scan index (0..63) to its natural row-major position in
/// an 8x8 block. `kJpegNaturalOrder[i]` is the raster index of the coefficient
/// coded `i`-th in scan order. The quantized coefficients are already stored in
/// this natural (raster) layout, so no separate de-zigzag is needed.
const List<int> kJpegNaturalOrder = <int>[
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, //
  27, 20, 13, 6, 7, 14, 21, 28, //
  35, 42, 49, 56, 57, 50, 43, 36, //
  29, 22, 15, 23, 30, 37, 44, 51, //
  58, 59, 52, 45, 38, 31, 39, 46, //
  53, 60, 61, 54, 47, 55, 62, 63, //
];

/// Stores the k jpeg huffman max bit length value used while processing JPEG XL data.
///
const int kJpegHuffmanMaxBitLength = 16;

/// Stores the k jpeg huffman alphabet size value used while processing JPEG XL data.
///
const int kJpegHuffmanAlphabetSize = 256;

/// Stores the k jpeg dc alphabet size value used while processing JPEG XL data.
///
const int kJpegDcAlphabetSize = 12;

/// Stores the k dct block size value used while processing JPEG XL data.
///
const int kDctBlockSize = 64;

/// App-marker type: which special payload (if any) a JPEG APPn marker carries.
/// kUnknown markers store their bytes verbatim in the jbrd Brotli tail; the
/// others reconstruct their payload from separate boxes (out of scope here).
/// Represents xmp data used while processing JPEG XL images.
///
enum AppMarkerType {
  /// Stores a marker whose payload has no specialized representation.
  unknown,

  /// Stores an ICC color-profile marker.
  icc,

  /// Stores an Exif metadata marker.
  exif,

  /// Stores an XMP metadata marker.
  xmp,
}

/// Quantization values for an 8x8 block. [values] are in natural (raster)
/// order and come from the codestream, not the jbrd box.
final class JpegQuantTable {
  /// Processes values information in a JPEG XL codestream.
  ///
  Int32List values = Int32List(kDctBlockSize);

  /// Stores the precision value used while processing JPEG XL data.
  ///
  int precision = 0;

  /// Stores the index value used while processing JPEG XL data.
  ///
  int index = 0;

  /// Stores the is last value used while processing JPEG XL data.
  ///
  bool isLast = true;
}

/// A JPEG Huffman table definition (DHT). [counts] is the 17-entry bit-length
/// histogram (index 0 unused); [values] are symbols sorted by increasing code
/// length. [slotId] packs is-AC (bit 4) and table id (low nibble).
final class JpegHuffmanCode {
  /// Processes counts information in a JPEG XL codestream.
  ///
  Uint32List counts = Uint32List(kJpegHuffmanMaxBitLength + 1);

  /// Processes values information in a JPEG XL codestream.
  ///
  Uint32List values = Uint32List(kJpegHuffmanAlphabetSize + 1);

  /// Stores the slot id value used while processing JPEG XL data.
  ///
  int slotId = 0;

  /// Stores the is last value used while processing JPEG XL data.
  ///
  bool isLast = true;
}

/// Per-component Huffman table selection within one scan.
final class JpegComponentScanInfo {
  /// Stores the comp idx value used while processing JPEG XL data.
  ///
  int compIdx = 0;

  /// Stores the dc tbl idx value used while processing JPEG XL data.
  ///
  int dcTblIdx = 0;

  /// Stores the ac tbl idx value used while processing JPEG XL data.
  ///
  int acTblIdx = 0;
}

/// One SOS scan's parameters. Ss/Se/Ah/Al are the progressive spectral-band /
/// successive-approximation fields (0/63/0/0 for baseline).
final class JpegScanInfo {
  /// Stores the ss value used while processing JPEG XL data.
  ///
  int ss = 0;

  /// Stores the se value used while processing JPEG XL data.
  ///
  int se = 63;

  /// Stores the ah value used while processing JPEG XL data.
  ///
  int ah = 0;

  /// Stores the al value used while processing JPEG XL data.
  ///
  int al = 0;

  /// Stores the num components value used while processing JPEG XL data.
  ///
  int numComponents = 0;

  /// Processes components information in a JPEG XL codestream.
  ///
  final List<JpegComponentScanInfo> components = List.generate(4, (_) => JpegComponentScanInfo(), growable: false);

  /// Stores the last needed pass value used while processing JPEG XL data.
  ///
  int lastNeededPass = 0;

  /// Block indices where end-of-band runs / refinement bits must be flushed.
  Uint32List resetPoints = Uint32List(0);

  /// Extra ZRL runs some encoders emit before end-of-block, as
  /// (blockIdx, numExtraZeroRuns) pairs flattened.
  List<({int blockIdx, int numExtraZeroRuns})> extraZeroRuns = const [];
}

/// One JPEG component: id, sampling factors, quant-table index, block-grid
/// dimensions, and the flat block-by-block natural-order quantized coeffs
/// (64 per block), filled from the decode.
final class JpegComponent {
  /// Stores the id value used while processing JPEG XL data.
  ///
  int id = 0;

  /// Stores the h samp factor value used while processing JPEG XL data.
  ///
  int hSampFactor = 1;

  /// Stores the v samp factor value used while processing JPEG XL data.
  ///
  int vSampFactor = 1;

  /// Stores the quant idx value used while processing JPEG XL data.
  ///
  int quantIdx = 0;

  /// Stores the width in blocks value used while processing JPEG XL data.
  ///
  int widthInBlocks = 0;

  /// Stores the height in blocks value used while processing JPEG XL data.
  ///
  int heightInBlocks = 0;

  /// `coeffs[(blockY * widthInBlocks + blockX) * 64 + naturalPos]`.
  Int32List coeffs = Int32List(0);
}

/// A parsed JPEG file's structure plus its recovered coefficients — the input
/// to [writeJpeg]. Mirrors libjxl `JPEGData`.
final class JpegData {
  /// Stores the width value used while processing JPEG XL data.
  ///
  int width = 0;

  /// Stores the height value used while processing JPEG XL data.
  ///
  int height = 0;

  /// Stores the restart interval value used while processing JPEG XL data.
  ///
  int restartInterval = 0;

  /// Each app_data entry is a full marker body: `[0xEn, sizeHi, sizeLo,
  /// payload...]` (the leading 0xFF is implicit).
  List<Uint8List> appData = [];

  /// Stores the app marker type value used while processing JPEG XL data.
  ///
  List<AppMarkerType> appMarkerType = [];

  /// Stores the com data value used while processing JPEG XL data.
  ///
  List<Uint8List> comData = [];

  /// Stores the quant value used while processing JPEG XL data.
  ///
  List<JpegQuantTable> quant = [];

  /// Stores the huffman code value used while processing JPEG XL data.
  ///
  List<JpegHuffmanCode> huffmanCode = [];

  /// Stores the components value used while processing JPEG XL data.
  ///
  List<JpegComponent> components = [];

  /// Stores the scan info value used while processing JPEG XL data.
  ///
  List<JpegScanInfo> scanInfo = [];

  /// The order in which markers appear (marker byte without the 0xFF prefix;
  /// 0xFF is a sentinel for inter-marker data). Drives re-emission.
  Uint8List markerOrder = Uint8List(0);

  /// Stores the inter marker data value used while processing JPEG XL data.
  ///
  List<Uint8List> interMarkerData = [];

  /// Processes tail data information in a JPEG XL codestream.
  ///
  Uint8List tailData = Uint8List(0);

  /// Stores the has zero padding bit value used while processing JPEG XL data.
  ///
  bool hasZeroPaddingBit = false;

  /// One bit per entry (0/1); the exact entropy-segment padding bits.
  Uint8List paddingBits = Uint8List(0);
}
