part of '../jpeg_xl.dart';

/// What a [JpegXlStreamingDecoder] can produce with the bytes seen so far.
enum JpegXlStreamState {
  /// Not enough bytes for anything yet.
  needsBytes,

  /// The image header is parsed: [JpegXlStreamingDecoder.info] is available.
  headersReady,

  /// The DC sections are buffered: [JpegXlStreamingDecoder.decodePreview]
  /// returns a 1:8 preview.
  dcReady,

  /// All frames are buffered: [JpegXlStreamingDecoder.decodeFinal] works
  /// (and the preview stays available for VarDCT images).
  complete,
}

/// Incremental decoding of a JPEG XL byte stream.
/// Feed bytes as they arrive with [addBytes]; [state] reports what is
/// achievable right now. For VarDCT images the DC sections (typically
/// 1–2% of the file) yield a 1:8 preview via [decodePreview] — the classic
/// blurry-then-sharp progressive experience. Modular (lossless) images
/// have no DC concept: they go straight from [JpegXlStreamState.headersReady]
/// to [JpegXlStreamState.complete], with [progress] still advancing.
/// [addBytes] only buffers; parsing happens lazily on [state]/[progress]/
/// [info] queries (headers and TOC only, cheap) and pixel decoding only in
/// [decodePreview]/[decodeFinal]. Malformed data throws
/// [JpegXlInvalidBitstreamException] from any of those.
final class JpegXlStreamingDecoder {
  /// Growable storage for the JPEG XL bytes received so far.
  Uint8List _buffer = Uint8List(64 * 1024);

  /// Number of received bytes currently stored in [_buffer].
  int _receivedByteCount = 0;

  /// Stream inspection cached for the current input length.
  _StreamInspection? _cachedInspection;

  /// Input length represented by [_cachedInspection].
  int _cachedInspectionByteCount = -1;

  /// Decoded preview cached for repeated requests.
  JpegXlDecodedImage? _cachedPreview;

  /// Creates an empty incremental JPEG XL decoder.
  JpegXlStreamingDecoder();

  /// Appends a chunk of the file. Cheap: no parsing happens here.
  void addBytes(List<int> chunk) {
    if (_receivedByteCount + chunk.length > _buffer.length) {
      int capacity = _buffer.length * 2;
      while (capacity < _receivedByteCount + chunk.length) {
        capacity *= 2;
      }
      final Uint8List grown = Uint8List(capacity);
      grown.setRange(0, _receivedByteCount, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(_receivedByteCount, _receivedByteCount + chunk.length, chunk);
    _receivedByteCount += chunk.length;
  }

  /// Total bytes buffered so far.
  int get bytesReceived => _receivedByteCount;

  /// Decoding milestone reached with the currently buffered bytes.
  JpegXlStreamState get state => _currentInspection().state;

  /// Parsed header info, once [state] is at least
  /// [JpegXlStreamState.headersReady].
  JpegXlCodestreamInfo? get info => _currentInspection().info;

  /// Fraction of the codestream buffered, in [0, 1]. Exact (and monotone)
  /// once the last frame's table of contents has been seen — for
  /// single-frame stills that is the first table of contents. Until the
  /// total extent is known it stays 0.
  double get progress {
    final _StreamInspection p = _currentInspection();
    if (p.state == JpegXlStreamState.complete) {
      return 1.0;
    }
    if (!p.hasLastFrameHeader || p.expectedEndByte <= 0) {
      return 0.0;
    }
    return math.min(1.0, p.availableCodestreamBytes / p.expectedEndByte);
  }

  /// Decodes the 1:8 DC preview. Returns null until [JpegXlStreamState.dcReady]
  /// (and always for images without a DC image, e.g. lossless modular).
  /// The result is cached; repeated calls are free.
  JpegXlDecodedImage? decodePreview() {
    if (_cachedPreview != null) {
      return _cachedPreview;
    }
    final _StreamInspection p = _currentInspection();
    if (!p.hasPreviewData) {
      return null;
    }
    return _cachedPreview = _decodePreview(p);
  }

  /// Decodes the complete image (first visible frame). Throws [StateError]
  /// unless [state] is [JpegXlStreamState.complete].
  JpegXlDecodedImage decodeFinal() {
    _requireComplete();
    return _JpegXlCodestreamDecoder.decode(_bytesCopy());
  }

  /// Decodes every visible frame after the stream becomes complete.
  JpegXlDecodedAnimation decodeFinalAnimation() {
    _requireComplete();
    return _JpegXlCodestreamDecoder.decodeAnimation(_bytesCopy());
  }

  /// Throws when a final decode is requested before all frame data arrived.
  void _requireComplete() {
    if (_currentInspection().state != JpegXlStreamState.complete) {
      throw StateError(
        'stream is not complete yet '
        '(${(progress * 100).toStringAsFixed(0)}% buffered)',
      );
    }
  }

  /// Returns an independent copy of the buffered bytes.
  Uint8List _bytesCopy() {
    final Uint8List out = Uint8List(_receivedByteCount);
    out.setRange(0, _receivedByteCount, _buffer);
    return out;
  }

  /// Zero-copy view over the portion of [_buffer] containing received bytes.
  Uint8List get _receivedBytesView => Uint8List.sublistView(_buffer, 0, _receivedByteCount);

  /// Returns the cached inspection for the current byte count.
  _StreamInspection _currentInspection() {
    if (_cachedInspectionByteCount == _receivedByteCount) {
      return _cachedInspection!;
    }
    final _StreamInspection inspection = _inspectBufferedData();
    _cachedInspection = inspection;
    _cachedInspectionByteCount = _receivedByteCount;
    return inspection;
  }

  /// Parses enough headers and section tables to classify buffered input.
  _StreamInspection _inspectBufferedData() {
    final Uint8List codestream;
    try {
      codestream = demuxContainerPartial(_receivedBytesView);
    } on JpegXlTruncatedException {
      return _StreamInspection.needsBytes();
    }

    final BitReader reader = BitReader(data: codestream);
    final ImageHeader header;
    try {
      // Probe permissively at level 10; the real decode enforces the
      // container's declared level.
      header = ImageHeader.read(reader: reader, level: 10);
      if (header.iccEncodedSize != null) {
        IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
        reader.zeroPadToByte();
      }
    } on JpegXlTruncatedException {
      return _StreamInspection.needsBytes();
    } on RangeError {
      return _StreamInspection.needsBytes();
    }

    final _StreamInspection inspection = _StreamInspection(header: header, availableCodestreamBytes: codestream.length);
    try {
      if (header.previewSize != null) {
        final Frame preview = Frame(globalReader: reader, globalMetadata: header);
        preview.readFrameHeader();
        preview.readTableOfContents();
      }
      bool sawRegularFrame = false;
      for (var i = 0; i < 1 << 20; i++) {
        final Frame frame = Frame(globalReader: reader, globalMetadata: header);
        final FrameHeader frameHeader = frame.readFrameHeader();
        frame.readTableOfContents(allowTruncated: true);
        final FrameTableOfContents tableOfContents = frame.tableOfContents;
        final bool frameComplete = tableOfContents.availablePayloadBytes >= tableOfContents.totalPayloadBytes;
        // In truncated mode the reader is left at the payload start;
        // otherwise it has been advanced past the payload.
        inspection.expectedEndByte = frameComplete ? reader.bitsRead >> 3 : (reader.bitsRead >> 3) + tableOfContents.totalPayloadBytes;
        final bool isRegular = frameHeader.type == FrameFlags.regularFrame || frameHeader.type == FrameFlags.skipProgressive;
        // A completed level-1 LF frame IS a 1:8 image (progressive-DC
        // files); every frame before it in the walk is already complete.
        if (!inspection.hasPreviewData && frameHeader.type == FrameFlags.lowFrequencyFrame && frameHeader.lowFrequencyLevel == 1 && frameComplete) {
          inspection.hasPreviewData = true;
          inspection.previewUsesLowFrequencyFrame = true;
        }
        if (!sawRegularFrame && isRegular) {
          sawRegularFrame = true;
          if (!inspection.hasPreviewData) {
            inspection.hasPreviewData = _hasCompleteLowFrequencySections(frame, header);
          }
        }
        if (frameHeader.isLast) {
          inspection.hasLastFrameHeader = true;
        }
        if (!frameComplete) {
          break;
        }
        if (frameHeader.isLast) {
          inspection.isComplete = true;
          break;
        }
      }
    } on JpegXlTruncatedException {
      // A later frame header/TOC is not buffered yet; keep what we have.
    } on RangeError {
      // Same: partial bytes mid-structure.
    }
    return inspection;
  }

  /// Whether all sections required for a low-frequency preview are present.
  static bool _hasCompleteLowFrequencySections(Frame frame, ImageHeader header) {
    final FrameHeader frameHeader = frame.header;
    if (frameHeader.encoding != FrameFlags.vardct) {
      return false;
    }
    if (frameHeader.flags & FrameFlags.useLfFrame != 0) {
      return false;
    }
    // A frame that doesn't cover the canvas would make a misleading preview.
    if (frameHeader.x0 != 0 || frameHeader.y0 != 0 || frameHeader.width < header.size.width || frameHeader.height < header.size.height) {
      return false;
    }
    if (frame.tableOfContentsEntryCount <= 1) {
      return false;
    }
    for (var i = 0; i <= frame.lowFrequencyGroupCount; i++) {
      if (!frame.tableOfContents.sectionAvailable(i)) {
        return false;
      }
    }
    return true;
  }

  /// Decodes a low-frequency preview from the inspected byte prefix.
  JpegXlDecodedImage _decodePreview(_StreamInspection inspection) {
    final Uint8List codestream = demuxContainerPartial(_receivedBytesView);
    final BitReader reader = BitReader(data: codestream);
    final ImageHeader header = ImageHeader.read(reader: reader, level: 10);
    Uint8List? iccProfile;
    if (header.iccEncodedSize != null) {
      final Uint8List encoded = IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
      reader.zeroPadToByte();
      iccProfile = IccCodec.decompress(encoded);
    }
    if (header.previewSize != null) {
      final Frame preview = Frame(globalReader: reader, globalMetadata: header);
      preview.readFrameHeader();
      preview.readTableOfContents();
    }
    // Walk to the preview source: the level-1 LF frame when present,
    // otherwise the first regular frame. Frames preceding the source were
    // fully buffered, or the probe would not have reported hasPreviewData.
    final List<List<ImageBuffer>?> lowFrequencyBuffers = List<List<ImageBuffer>?>.filled(5, null);
    for (var i = 0; i < 1 << 20; i++) {
      final Frame frame = Frame(globalReader: reader, globalMetadata: header);
      final FrameHeader frameHeader = frame.readFrameHeader();
      frame.readTableOfContents(allowTruncated: true);
      if (inspection.previewUsesLowFrequencyFrame && frameHeader.type == FrameFlags.lowFrequencyFrame) {
        frame.decodeFrame(lowFrequencyFrame: lowFrequencyBuffers[frameHeader.lowFrequencyLevel]);
        if (frameHeader.lowFrequencyLevel == 1) {
          return buildDcImageFromRows([for (var c = 0; c < 3; c++) frame.buffer[c].floatRows], frame.paddedFrameSize.height, frame.paddedFrameSize.width, frame.header.usesYcbcr, header, iccProfile);
        }
        lowFrequencyBuffers[frameHeader.lowFrequencyLevel - 1] = frame.buffer;
        continue;
      }
      if (frameHeader.type == FrameFlags.regularFrame || frameHeader.type == FrameFlags.skipProgressive) {
        frame.decodeLfOnly();
        return buildDcImage(frame, header, iccProfile);
      }
    }
    throw const JpegXlInvalidBitstreamException(message: 'no visible frame found');
  }
}

/// Header and section availability discovered without decoding pixels.
final class _StreamInspection {
  /// Parsed public metadata, or `null` while the image header is incomplete.
  final JpegXlCodestreamInfo? info;

  /// Number of demultiplexed codestream bytes currently available.
  final int availableCodestreamBytes;

  /// Expected byte immediately after the final declared frame payload.
  int expectedEndByte = 0;

  /// Whether the buffered sections can produce a low-frequency preview.
  bool hasPreviewData = false;

  /// Whether preview pixels must come from a level-one low-frequency frame.
  bool previewUsesLowFrequencyFrame = false;

  /// Whether the final frame header has been observed.
  bool hasLastFrameHeader = false;

  /// Whether all frame data has been received.
  bool isComplete = false;

  /// Creates a successful inspection from a decoded [header].
  _StreamInspection({
    required ImageHeader header,
    required this.availableCodestreamBytes,
  }) : info = JpegXlCodestreamInfo.internal(header: header, isContainer: false);

  /// Creates an inspection representing an incomplete image header.
  _StreamInspection.needsBytes() : info = null, availableCodestreamBytes = 0;

  /// Most advanced decoding operation supported by the buffered data.
  JpegXlStreamState get state {
    if (info == null) {
      return JpegXlStreamState.needsBytes;
    }
    if (isComplete) {
      return JpegXlStreamState.complete;
    }
    if (hasPreviewData) {
      return JpegXlStreamState.dcReady;
    }
    return JpegXlStreamState.headersReady;
  }
}
