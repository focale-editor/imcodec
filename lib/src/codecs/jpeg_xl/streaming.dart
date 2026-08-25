import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/decoder.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_flags.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/frame_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/frame/toc.dart';
import 'package:imcodec/src/codecs/jpeg_xl/header/image_header.dart';
import 'package:imcodec/src/codecs/jpeg_xl/icc/icc_codec.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/container.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl_image.dart';
import 'package:imcodec/src/codecs/jpeg_xl/jpeg_xl_info.dart';
import 'package:imcodec/src/codecs/jpeg_xl/render/dc_image.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/image_buffer.dart';

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
///
/// Feed bytes as they arrive with [addBytes]; [state] reports what is
/// achievable right now. For VarDCT images the DC sections (typically
/// 1–2% of the file) yield a 1:8 preview via [decodePreview] — the classic
/// blurry-then-sharp progressive experience. Modular (lossless) images
/// have no DC concept: they go straight from [JpegXlStreamState.headersReady]
/// to [JpegXlStreamState.complete], with [progress] still advancing.
///
/// [addBytes] only buffers; parsing happens lazily on [state]/[progress]/
/// [info] queries (headers and TOC only, cheap) and pixel decoding only in
/// [decodePreview]/[decodeFinal]. Malformed data throws
/// [JpegXlInvalidBitstreamException] from any of those.
final class JpegXlStreamingDecoder {
  /// Processes the data data used by the JPEG XL codec.
  ///
  Uint8List _data = Uint8List(64 * 1024);

  /// Stores the length state used internally by the JPEG XL codec.
  ///
  int _length = 0;

  /// Stores the probe cache state used by the JPEG XL codec.
  ///
  _Probe? _probeCache;

  /// Stores the probe cache length state used internally by the JPEG XL codec.
  ///
  int _probeCacheLength = -1;

  /// Stores the cached preview state used internally by the JPEG XL codec.
  ///
  JpegXlDecodedImage? _cachedPreview;

  /// Appends a chunk of the file. Cheap: no parsing happens here.
  void addBytes(List<int> chunk) {
    if (_length + chunk.length > _data.length) {
      int capacity = _data.length * 2;
      while (capacity < _length + chunk.length) {
        capacity *= 2;
      }
      final grown = Uint8List(capacity);
      grown.setRange(0, _length, _data);
      _data = grown;
    }
    _data.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
  }

  /// Total bytes buffered so far.
  int get bytesReceived => _length;

  /// Processes state information in a JPEG XL codestream.
  ///
  JpegXlStreamState get state => _probe().state;

  /// Parsed header info, once [state] is at least
  /// [JpegXlStreamState.headersReady].
  JpegXlCodestreamInfo? get info => _probe().info;

  /// Fraction of the codestream buffered, in [0, 1]. Exact (and monotone)
  /// once the last frame's table of contents has been seen — for
  /// single-frame stills that is the first table of contents. Until the
  /// total extent is known it stays 0.
  double get progress {
    final _Probe p = _probe();
    if (p.state == JpegXlStreamState.complete) {
      return 1.0;
    }
    if (!p.sawLastFrame || p.knownEndByte <= 0) {
      return 0.0;
    }
    return math.min(1.0, p.codestreamLength / p.knownEndByte);
  }

  /// Decodes the 1:8 DC preview. Returns null until [JpegXlStreamState.dcReady]
  /// (and always for images without a DC image, e.g. lossless modular).
  /// The result is cached; repeated calls are free.
  JpegXlDecodedImage? decodePreview() {
    if (_cachedPreview != null) {
      return _cachedPreview;
    }
    final _Probe p = _probe();
    if (!p.dcAvailable) {
      return null;
    }
    return _cachedPreview = _decodePreview(p);
  }

  /// Decodes the complete image (first visible frame). Throws [StateError]
  /// unless [state] is [JpegXlStreamState.complete].
  JpegXlDecodedImage decodeFinal() {
    _requireComplete();
    return JpegXlCodestreamDecoder.decode(_bytesCopy());
  }

  /// Decodes all frames of the complete image.
  JpegXlDecodedAnimation decodeFinalAnimation() {
    _requireComplete();
    return JpegXlCodestreamDecoder.decodeAnimation(_bytesCopy());
  }

  /// Processes the require complete data used by the JPEG XL codec.
  ///
  void _requireComplete() {
    if (_probe().state != JpegXlStreamState.complete) {
      throw StateError(
        'stream is not complete yet '
        '(${(progress * 100).toStringAsFixed(0)}% buffered)',
      );
    }
  }

  /// Processes the bytes copy data used by the JPEG XL codec.
  ///
  Uint8List _bytesCopy() {
    final out = Uint8List(_length);
    out.setRange(0, _length, _data);
    return out;
  }

  /// Processes the view data used by the JPEG XL codec.
  ///
  Uint8List get _view => Uint8List.sublistView(_data, 0, _length);

  /// Processes probe data for the JPEG XL codec.
  ///
  _Probe _probe() {
    if (_probeCacheLength == _length) {
      return _probeCache!;
    }
    final _Probe probe = _computeProbe();
    _probeCache = probe;
    _probeCacheLength = _length;
    return probe;
  }

  /// Processes compute probe data for the JPEG XL codec.
  ///
  _Probe _computeProbe() {
    final Uint8List codestream;
    try {
      codestream = demuxContainerPartial(_view);
    } on JpegXlTruncatedException {
      return _Probe.needsBytes();
    }

    final reader = BitReader(data: codestream);
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
      return _Probe.needsBytes();
    } on RangeError {
      return _Probe.needsBytes();
    }

    final probe = _Probe(header: header, codestreamLength: codestream.length);
    try {
      if (header.previewSize != null) {
        final preview = Frame(globalReader: reader, globalMetadata: header);
        preview.readFrameHeader();
        preview.readToc();
      }
      var sawRegularFrame = false;
      for (var i = 0; i < 1 << 20; i++) {
        final frame = Frame(globalReader: reader, globalMetadata: header);
        final FrameHeader fh = frame.readFrameHeader();
        frame.readToc(allowTruncated: true);
        final Toc toc = frame.toc;
        final bool frameComplete = toc.availableBytes >= toc.totalBytes;
        // In truncated mode the reader is left at the payload start;
        // otherwise it has been advanced past the payload.
        probe.knownEndByte = frameComplete ? reader.bitsRead >> 3 : (reader.bitsRead >> 3) + toc.totalBytes;
        final bool isRegular = fh.type == FrameFlags.regularFrame || fh.type == FrameFlags.skipProgressive;
        // A completed level-1 LF frame IS a 1:8 image (progressive-DC
        // files); every frame before it in the walk is already complete.
        if (!probe.dcAvailable && fh.type == FrameFlags.lfFrame && fh.lfLevel == 1 && frameComplete) {
          probe.dcAvailable = true;
          probe.previewFromLfFrame = true;
        }
        if (!sawRegularFrame && isRegular) {
          sawRegularFrame = true;
          if (!probe.dcAvailable) {
            probe.dcAvailable = _dcSectionsAvailable(frame, header);
          }
        }
        if (fh.isLast) {
          probe.sawLastFrame = true;
        }
        if (!frameComplete) {
          break;
        }
        if (fh.isLast) {
          probe.allFramesBuffered = true;
          break;
        }
      }
    } on JpegXlTruncatedException {
      // A later frame header/TOC is not buffered yet; keep what we have.
    } on RangeError {
      // Same: partial bytes mid-structure.
    }
    return probe;
  }

  /// Processes the dc sections available data used by the JPEG XL codec.
  ///
  static bool _dcSectionsAvailable(Frame frame, ImageHeader header) {
    final FrameHeader fh = frame.header;
    if (fh.encoding != FrameFlags.vardct) {
      return false;
    }
    if (fh.flags & FrameFlags.useLfFrame != 0) {
      return false;
    }
    // A frame that doesn't cover the canvas would make a misleading preview.
    if (fh.x0 != 0 || fh.y0 != 0 || fh.width < header.size.width || fh.height < header.size.height) {
      return false;
    }
    if (frame.tocEntryCount <= 1) {
      return false;
    }
    for (var i = 0; i <= frame.numLfGroups; i++) {
      if (!frame.toc.sectionAvailable(i)) {
        return false;
      }
    }
    return true;
  }

  /// Decodes preview.
  ///
  JpegXlDecodedImage _decodePreview(_Probe probe) {
    final Uint8List codestream = demuxContainerPartial(_view);
    final reader = BitReader(data: codestream);
    final header = ImageHeader.read(reader: reader, level: 10);
    Uint8List? iccProfile;
    if (header.iccEncodedSize != null) {
      final Uint8List encoded = IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
      reader.zeroPadToByte();
      iccProfile = IccCodec.decompress(encoded);
    }
    if (header.previewSize != null) {
      final preview = Frame(globalReader: reader, globalMetadata: header);
      preview.readFrameHeader();
      preview.readToc();
    }
    // Walk to the preview source: the level-1 LF frame when present,
    // otherwise the first regular frame. Frames preceding the source were
    // fully buffered, or the probe would not have reported dcAvailable.
    final lfBuffers = List<List<ImageBuffer>?>.filled(5, null);
    for (var i = 0; i < 1 << 20; i++) {
      final frame = Frame(globalReader: reader, globalMetadata: header);
      final FrameHeader fh = frame.readFrameHeader();
      frame.readToc(allowTruncated: true);
      if (probe.previewFromLfFrame && fh.type == FrameFlags.lfFrame) {
        frame.decodeFrame(lfFrame: lfBuffers[fh.lfLevel]);
        if (fh.lfLevel == 1) {
          return buildDcImageFromRows([for (var c = 0; c < 3; c++) frame.buffer[c].floatRows], frame.paddedFrameSize.height, frame.paddedFrameSize.width, frame.header.doYCbCr, header, iccProfile);
        }
        lfBuffers[fh.lfLevel - 1] = frame.buffer;
        continue;
      }
      if (fh.type == FrameFlags.regularFrame || fh.type == FrameFlags.skipProgressive) {
        frame.decodeLfOnly();
        return buildDcImage(frame, header, iccProfile);
      }
    }
    throw const JpegXlInvalidBitstreamException(message: 'no visible frame found');
  }
}

/// Creates an internal probe.
///
final class _Probe {
  /// Stores the info state used by the JPEG XL codec.
  ///
  final JpegXlCodestreamInfo? info;

  /// Stores the codestream length state used by the JPEG XL codec.
  ///
  final int codestreamLength;

  /// Stores the known end byte state used by the JPEG XL codec.
  ///
  int knownEndByte = 0;

  /// Stores the dc available state used by the JPEG XL codec.
  ///
  bool dcAvailable = false;

  /// Stores the preview from lf frame state used by the JPEG XL codec.
  ///
  bool previewFromLfFrame = false;

  /// Stores the saw last frame state used by the JPEG XL codec.
  ///
  bool sawLastFrame = false;

  /// Stores the all frames buffered state used by the JPEG XL codec.
  ///
  bool allFramesBuffered = false;

  /// Creates an internal probe.
  ///
  _Probe({
    required ImageHeader header,
    required this.codestreamLength,
  }) : info = JpegXlCodestreamInfo.internal(header: header, isContainer: false);

  /// Creates an internal probe.
  ///
  _Probe.needsBytes() : info = null, codestreamLength = 0;

  /// Processes state data for the JPEG XL codec.
  ///
  JpegXlStreamState get state {
    if (info == null) {
      return JpegXlStreamState.needsBytes;
    }
    if (allFramesBuffered) {
      return JpegXlStreamState.complete;
    }
    if (dcAvailable) {
      return JpegXlStreamState.dcReady;
    }
    return JpegXlStreamState.headersReady;
  }
}
