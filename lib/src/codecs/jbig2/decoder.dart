part of '../jbig2.dart';

/// Decodes JBIG2 pages into opaque black-and-white RGBA pixels.
final class Jbig2Decoder extends RasterDecoder<Jbig2DecodeOptions> {
  /// Creates a decoder with bounded page and working allocations.
  const Jbig2Decoder({Jbig2DecodeOptions defaultOptions = const Jbig2DecodeOptions()}) : super(defaultDecodeOptions: defaultOptions);

  @override
  Image decodeWithOptions(Uint8List input, Jbig2DecodeOptions options) {
    if (!ImageFormat.jbig2.matches(input)) {
      throw const ImageCodecException('Expected a standalone JBIG2 file');
    }
    return _decode(input, null, options);
  }

  /// Decodes a PDF segment stream with its optional JBIG2Globals bytes.
  ///
  /// The PDF container must decompress the globals stream before passing it.
  Image decodeEmbedded(Uint8List input, {Uint8List? globals, Jbig2DecodeOptions? decodeOptions}) => _decode(input, globals, decodeOptions ?? defaultDecodeOptions);

  /// Maps the selected page and converts the composed one-bit bitmap to RGBA.
  Image _decode(Uint8List input, Uint8List? globals, Jbig2DecodeOptions options) {
    if (options.maxPixels < 1) {
      throw RangeError.range(options.maxPixels, 1, null, 'maxPixels');
    }
    if (options.page < 1) {
      throw RangeError.range(options.page, 1, null, 'page');
    }
    if (options.maxWorkingBytes < 1) {
      throw RangeError.range(options.maxWorkingBytes, 1, null, 'maxWorkingBytes');
    }
    if (options.maxSegments < 1) {
      throw RangeError.range(options.maxSegments, 1, null, 'maxSegments');
    }
    return runZoned(() {
      try {
        final _Jbig2Document? globalDocument = globals == null ? null : _Jbig2Document(bytes: globals, maxSegments: options.maxSegments);
        if (globalDocument != null && globalDocument.pages.isNotEmpty) {
          throw const ImageCodecException('JBIG2 globals must not contain pages');
        }
        final _Jbig2Document document = _Jbig2Document(bytes: input, maxSegments: options.maxSegments, globals: globalDocument?.globals);
        final _Jbig2Page? page = document.pages[options.page];
        if (page == null) {
          throw ImageCodecException('JBIG2 has no page ${options.page}');
        }
        final _Jbig2Segment? header = page.getPageInformationSegment();
        if (header == null) {
          throw const ImageCodecException('JBIG2 page information is missing');
        }
        final _Jbig2PageInformation information = header.getSegmentData()! as _Jbig2PageInformation;
        _Jbig2Budget.current.checkDimensions(information.bitmapWidth, information.bitmapHeight == -1 ? page.getHeight() : information.bitmapHeight);
        final _Jbig2Bitmap bitmap = page.getBitmap();
        _Jbig2Budget.current.checkDimensions(bitmap.width, bitmap.height);
        final Uint8List pixels = Uint8List(bitmap.width * bitmap.height * 4);
        for (int y = 0; y < bitmap.height; y++) {
          for (int x = 0; x < bitmap.width; x++) {
            final int offset = (y * bitmap.width + x) * 4;
            final int value = bitmap.getPixel(x, y) == 0 ? 255 : 0;
            pixels[offset] = value;
            pixels[offset + 1] = value;
            pixels[offset + 2] = value;
            pixels[offset + 3] = 255;
          }
        }
        return Image.fromRgba(width: bitmap.width, height: bitmap.height, bytes: pixels);
      } on ImageCodecException {
        rethrow;
      } on Object catch (error, stack) {
        Error.throwWithStackTrace(ImageCodecException('Could not decode the JBIG2 image', cause: error), stack);
      }
    }, zoneValues: {_Jbig2Budget: _Jbig2Budget(options: options)});
  }
}

/// Allocation limits and page selection for JBIG2 decoding.
final class Jbig2DecodeOptions extends RasterDecodeOptions {
  /// One-based JBIG2 page association to decode.
  final int page;

  /// Maximum cumulative working storage for bitmaps and entropy tables.
  ///
  /// This also bounds symbol counts and refinement buffers, independently
  /// of the final RGBA page's [maxPixels] limit.
  final int maxWorkingBytes;

  /// Maximum segment count in each page or globals stream.
  final int maxSegments;

  /// Creates options for the first page with bounded working memory.
  const Jbig2DecodeOptions({super.maxPixels, this.page = 1, this.maxWorkingBytes = 256 * 1024 * 1024, this.maxSegments = 100000});
}

/// Per-decode allocation accounting, isolated from nested or concurrent calls.
final class _Jbig2Budget {
  /// Limits configured by the caller.
  final Jbig2DecodeOptions options;

  /// Total intermediate bitmap storage allocated during this decode.
  int _allocated = 0;

  /// Creates a new allocation ledger.
  _Jbig2Budget({required this.options});

  /// Active synchronous decoding budget.
  static _Jbig2Budget get current => Zone.current[_Jbig2Budget] as _Jbig2Budget;

  /// Rejects empty or excessively large page and region dimensions.
  void checkDimensions(int width, int height) {
    if (width < 1 || height < 1 || width > options.maxPixels ~/ height) {
      throw const ImageCodecException('JBIG2 dimensions exceed the pixel limit or are invalid');
    }
  }

  /// Reserves working storage for tables and rejects excessive counts.
  static int reserve(int count, int bytesPerElement) {
    final _Jbig2Budget? budget = Zone.current[_Jbig2Budget] as _Jbig2Budget?;
    if (count < 0 || (budget != null && count > (budget.options.maxWorkingBytes - budget._allocated) ~/ bytesPerElement)) {
      throw const ImageCodecException('JBIG2 exceeds the working memory limit');
    }
    if (budget != null) {
      budget._allocated += count * bytesPerElement;
    }
    return count;
  }

  /// Allocates one packed bitmap after enforcing cumulative working limits.
  static Uint8List allocate(int width, int height) {
    final _Jbig2Budget? budget = Zone.current[_Jbig2Budget] as _Jbig2Budget?;
    if (width < 0 || height < 0) {
      throw const ImageCodecException('Negative JBIG2 bitmap dimensions');
    }
    if (budget != null && width != 0 && height != 0) {
      budget.checkDimensions(width, height);
    }
    final int size = ((width + 7) ~/ 8) * height;
    if (budget != null) {
      if (size > budget.options.maxWorkingBytes - budget._allocated) {
        throw const ImageCodecException('JBIG2 exceeds the working memory limit');
      }
      budget._allocated += size;
    }
    return Uint8List(size);
  }
}

/// Inspects a standalone JBIG2 page without allocating or decoding bitmaps.
DecodedImageMetadata inspectJbig2Container(Uint8List bytes, {int page = 1}) {
  try {
    final _Jbig2Document document = _Jbig2Document(bytes: bytes, maxSegments: 100000);
    final _Jbig2Page? target = document.pages[page];
    if (target == null) {
      throw ImageCodecException('JBIG2 has no page $page');
    }
    final _Jbig2PageInformation info = target.information;
    final int height = target.getHeight();
    if (info.bitmapWidth < 1 || height < 1) {
      throw const ImageCodecException('Invalid JBIG2 page dimensions');
    }
    return DecodedImageMetadata(width: info.bitmapWidth, height: height, bitsPerChannel: 8, colorModel: DecodedColorModel.rgb);
  } on ImageCodecException {
    rethrow;
  } on Object catch (error) {
    throw ImageCodecException('Could not inspect the JBIG2 image', cause: error);
  }
}
