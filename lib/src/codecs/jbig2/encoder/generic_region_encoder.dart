// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../jbig2.dart';

/// Encodes a bi-level bitmap as a JBIG2 generic region (T.88 clause 6.2).
///
/// All four templates of 6.2.5.3 are supported, the extended template of
/// EXTTEMPLATE included, with the nominal adaptive pixels or with any other
/// causal ones. _Jbig2Template 0 with the nominal AT pixels
/// — what general purpose encoders emit for scanned pages — goes through a
/// byte-wide context recurrence that is the exact mirror of the decoder's
/// `_decodeTemplate0a`; every other combination goes through a per-pixel path
/// that gathers the template straight from the figures of 6.2.5.3. Deriving
/// the fast path from the decoder rather than from the figures is deliberate:
/// it makes encoder and decoder agree by construction, and the round-trip
/// tests check both paths against the decoder.
class _Jbig2GenericRegionEncoder {
  /// The source image. Set bits are black, as everywhere in this package.
  final _Jbig2Bitmap bitmap;

  /// Emit typical prediction (TPGDON) so a row identical to the one above
  /// costs a single decision instead of a full row of pixels.
  final bool typicalPrediction;

  /// GBTEMPLATE of 7.4.6.2, 0 to 3.
  final int template;

  /// EXTTEMPLATE of 7.4.6.2: template 0 with twelve adaptive pixels instead of
  /// four (6.2.5.3, figure 8).
  ///
  /// The extended template covers the same sixteen neighbours as template 0
  /// does with its nominal adaptive pixels — only three of the sixteen stay
  /// fixed besides the pixel to the left — so with the nominal positions it
  /// codes to the very same bits. It earns its twenty-four header bytes only
  /// when the adaptive pixels are moved to follow a periodic pattern such as a
  /// halftone screen.
  final bool extTemplate;

  /// GBATX: one entry for templates 1 to 3, four for template 0 and twelve
  /// when [extTemplate] is set (7.4.6.3).
  final List<int> atX;

  /// GBATY, paired with [atX].
  final List<int> atY;

  /// 6.2.5.6 SKIP: pixels masked here are not coded at all, and the decoder
  /// leaves them at 0. They must already be 0 in [bitmap].
  final _Jbig2Bitmap? skip;

  /// Creates the generic region encoder state.
  _Jbig2GenericRegionEncoder({
    required this.bitmap,
    this.typicalPrediction = true,
    this.template = 0,
    this.extTemplate = false,
    List<int>? atX,
    List<int>? atY,
  }) : skip = null,
       atX = atX ?? nominalAtX(template, extTemplate: extTemplate),
       atY = atY ?? nominalAtY(template, extTemplate: extTemplate) {
    if (template < 0 || template > 3) {
      throw ArgumentError('GBTEMPLATE is 0 to 3, not $template.');
    }
    if (extTemplate && template != 0) {
      throw ArgumentError('EXTTEMPLATE only applies to GBTEMPLATE 0.');
    }
    final int needed = template == 0 ? (extTemplate ? 12 : 4) : 1;
    if (this.atX.length < needed || this.atY.length < needed) {
      throw ArgumentError(
        '${extTemplate ? 'The extended template' : '_Jbig2Template $template'} '
        'needs $needed adaptive pixels.',
      );
    }
    for (int i = 0; i < needed; i++) {
      final int x = this.atX[i];
      final int y = this.atY[i];
      if (y > 0 || (y == 0 && x >= 0)) {
        throw ArgumentError(
          'Adaptive pixel ${i + 1} at ($x, $y) is not yet decoded when the '
          'current pixel is coded.',
        );
      }
    }
  }

  /// The nominal AT abscissae of 6.2.5.3 for [template].
  static List<int> nominalAtX(int template, {bool extTemplate = false}) {
    if (template == 0) {
      return extTemplate ? _nominalExtAtX : const [3, -3, 2, -2];
    }
    return template == 1 ? const [3] : const [2];
  }

  /// The nominal AT ordinates of 6.2.5.3 for [template].
  static List<int> nominalAtY(int template, {bool extTemplate = false}) {
    if (template == 0) {
      return extTemplate ? _nominalExtAtY : const [-1, -1, -2, -2];
    }
    return const [-1];
  }

  /// The nominal positions of A1 to A12 in the extended template of figure 8.
  static const List<int> _nominalExtAtX = [
    -2, 0, -2, -1, 1, 2, -3, -4, 2, 3, -2, -3, //
  ];

  /// Stores nominal ext at y.
  static const List<int> _nominalExtAtY = [
    0, -2, -1, -2, -2, -1, 0, 0, -2, -1, -2, -1, //
  ];

  /// Context values 6.2.5.7 reserves for the TPGDON decision, one per
  /// template.
  static const List<int> sltpContexts = [0x9b25, 0x0795, 0x00e5, 0x0195];

  /// The template pixels of 6.2.5.3, most significant bit of the context
  /// first, with the adaptive pixels written as negative markers: -1 is AT1,
  /// -2 is AT2 and so on.
  static const List<List<List<int>>> _templates = [
    // Figure 4, GBTEMPLATE 0: 16 pixels.
    [
      [-4, 0], [-1, -2], [0, -2], [1, -2], [-3, 0], [-2, 0], //
      [-2, -1], [-1, -1], [0, -1], [1, -1], [2, -1], [-1, 0], //
      [-4, 0], [-3, 0], [-2, 0], [-1, 0],
    ],
    // Figure 5, GBTEMPLATE 1: 13 pixels.
    [
      [-1, -2], [0, -2], [1, -2], [2, -2], //
      [-2, -1], [-1, -1], [0, -1], [1, -1], [2, -1], [-1, 0], //
      [-3, 0], [-2, 0], [-1, 0],
    ],
    // Figure 6, GBTEMPLATE 2: 10 pixels.
    [
      [-1, -2], [0, -2], [1, -2], //
      [-2, -1], [-1, -1], [0, -1], [1, -1], [-1, 0], //
      [-2, 0], [-1, 0],
    ],
    // Figure 7, GBTEMPLATE 3: 10 pixels.
    [
      [-3, -1], [-2, -1], [-1, -1], [0, -1], [1, -1], [-1, 0], //
      [-4, 0], [-3, 0], [-2, 0], [-1, 0],
    ],
  ];

  /// Where each template's adaptive pixels sit in the pixel list above; the
  /// entry at index `i` is the position of AT`i+1`.
  static const List<List<int>> _atSlots = [
    [11, 5, 4, 0],
    [9],
    [7],
    [5],
  ];

  /// Figure 8, GBTEMPLATE 0 with EXTTEMPLATE: the same sixteen neighbours as
  /// figure 4, but only `(-1, -1)`, `(0, -1)`, `(1, -1)` and `(-1, 0)` are
  /// fixed. The entries below are the nominal positions of A1 to A12, which
  /// [_resolvedTemplate] replaces with the ones actually in use.
  static const List<List<int>> _extTemplate = [
    [-2, -2], [-1, -2], [0, -2], [1, -2], [2, -2], //
    [-3, -1], [-2, -1], [-1, -1], [0, -1], [1, -1], [2, -1], [3, -1], //
    [-4, 0], [-3, 0], [-2, 0], [-1, 0],
  ];

  /// Where A1 to A12 sit in [_extTemplate]. The order looks scrambled because
  /// the standard numbers the adaptive pixels by usefulness while the context
  /// is assembled by position, top-left first.
  static const List<int> _extAtSlots = [
    14, 2, 6, 1, 3, 10, 13, 12, 4, 11, 0, 5, //
  ];

  /// True when the adaptive pixels are the nominal ones, which lets the fast
  /// path run.
  bool get usesNominalAt {
    final List<int> nominalX = nominalAtX(template, extTemplate: extTemplate);
    final List<int> nominalY = nominalAtY(template, extTemplate: extTemplate);
    for (int i = 0; i < nominalX.length; i++) {
      if (atX[i] != nominalX[i] || atY[i] != nominalY[i]) {
        return false;
      }
    }
    return true;
  }

  /// Encodes the bitmap and returns the arithmetic codeword.
  Uint8List encode() {
    final _Jbig2MqEncoder encoder = _Jbig2MqEncoder();
    final _Jbig2ArithmeticContext cx = _Jbig2ArithmeticContext(size: 1 << 16, index: 0);
    encodeInto(encoder, cx);
    return encoder.flush();
  }

  /// Appends the decisions to an arithmetic stream shared by a segment.
  void encodeInto(_Jbig2MqEncoder encoder, _Jbig2ArithmeticContext cx) {
    final int width = bitmap.width;
    final int height = bitmap.height;
    final int rowStride = bitmap.rowStride;
    final int paddedWidth = (width + 7) & -8;
    final bool fast = template == 0 && !extTemplate && usesNominalAt;
    final List<List<int>> positions = fast ? const <List<int>>[] : _resolvedTemplate();

    int ltp = 0;
    for (int line = 0; line < height; line++) {
      if (typicalPrediction) {
        final bool duplicate = line > 0 && _rowsMatch(line, line - 1);
        final int wanted = duplicate ? 1 : 0;
        cx.index = sltpContexts[template];
        encoder.encode(cx, ltp ^ wanted);
        ltp = wanted;
        if (ltp == 1) {
          continue;
        }
      }
      if (fast) {
        _encodeLine(encoder, cx, line, width, rowStride, paddedWidth);
      } else {
        _encodeLineGeneric(encoder, cx, line, width, positions);
      }
    }
  }

  /// The template pixel list with the adaptive markers replaced by this
  /// encoder's actual AT positions.
  List<List<int>> _resolvedTemplate() {
    final List<List<int>> figure = extTemplate ? _extTemplate : _templates[template];
    final List<List<int>> positions = [
      for (final pixel in figure) [pixel[0], pixel[1]],
    ];
    final List<int> slots = extTemplate ? _extAtSlots : _atSlots[template];
    for (int i = 0; i < slots.length; i++) {
      positions[slots[i]] = [atX[i], atY[i]];
    }
    return positions;
  }

  /// 6.2.5.7 d): gathers the template around every pixel of one row.
  void _encodeLineGeneric(_Jbig2MqEncoder encoder, _Jbig2ArithmeticContext cx, int line, int width, List<List<int>> positions) {
    for (int x = 0; x < width; x++) {
      int context = 0;
      for (final pixel in positions) {
        context = (context << 1) | _pixel(x + pixel[0], line + pixel[1]);
      }
      if (_isSkipped(x, line)) {
        continue;
      }
      cx.index = context;
      encoder.encode(cx, bitmap.getPixel(x, line));
    }
  }

  /// 6.2.5.6: a masked pixel costs no decision at all.
  bool _isSkipped(int x, int y) {
    final _Jbig2Bitmap? mask = skip;
    if (mask == null) {
      return false;
    }
    if (x >= mask.width || y >= mask.height) {
      return false;
    }
    return mask.getPixel(x, y) == 1;
  }

  /// Computes pixel.
  int _pixel(int x, int y) {
    if (x < 0 || y < 0 || x >= bitmap.width || y >= bitmap.height) {
      return 0;
    }
    return bitmap.getPixel(x, y);
  }

  /// Computes rows match.
  bool _rowsMatch(int a, int b) {
    final int stride = bitmap.rowStride;
    final Uint8List data = bitmap.bitmap;
    final int left = a * stride;
    final int right = b * stride;
    for (int i = 0; i < stride; i++) {
      if (data[left + i] != data[right + i]) {
        return false;
      }
    }
    return true;
  }

  /// Encodes line.
  void _encodeLine(_Jbig2MqEncoder encoder, _Jbig2ArithmeticContext cx, int lineNumber, int width, int rowStride, int paddedWidth) {
    final int byteIndex = bitmap.getByteIndex(0, lineNumber);
    int idx = byteIndex - rowStride;

    int line1 = 0;
    int line2 = 0;
    if (lineNumber >= 1) {
      line1 = bitmap.getByte(idx);
    }
    if (lineNumber >= 2) {
      line2 = bitmap.getByte(idx - rowStride) << 6;
    }

    int context = (line1 & 0xf0) | (line2 & 0x3800);
    int current = byteIndex;

    int nextByte;
    for (int x = 0; x < paddedWidth; x = nextByte) {
      nextByte = x + 8;
      final int minorWidth = width - x > 8 ? 8 : width - x;
      final int source = bitmap.getByte(current);

      if (lineNumber > 0) {
        line1 = (line1 << 8) | (nextByte < width ? bitmap.getByte(idx + 1) : 0);
      }
      if (lineNumber > 1) {
        line2 = (line2 << 8) | (nextByte < width ? bitmap.getByte(idx - rowStride + 1) << 6 : 0);
      }

      for (int minorX = 0; minorX < minorWidth; minorX++) {
        final int toShift = 7 - minorX;
        final int bit = (source >> toShift) & 1;
        if (!_isSkipped(x + minorX, lineNumber)) {
          cx.index = context;
          encoder.encode(cx, bit);
        }
        context = ((context & 0x7bf7) << 1) | bit | ((line1 >> toShift) & 0x10) | ((line2 >> toShift) & 0x800);
      }

      current++;
      idx++;
    }
  }
}
