part of '../jpeg_xl.dart';

/// Decodes JPEG XL images to straight-alpha RGBA pixels.
final class JpegXlDecoder extends RasterDecoder {
  /// Creates a JPEG XL decoder.
  const JpegXlDecoder();

  @override
  Image decode(Uint8List encoded, {required int maxPixels}) {
    final JpegXlCodestreamInfo information = JpegXlCodestreamInfo.fromBytes(bytes: encoded);
    final int pixelCount = information.width * information.height;
    if (information.width < 1 || information.height < 1) {
      throw const ImageCodecException('Image dimensions must be positive and non-zero');
    }
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
    final JpegXlDecodedImage decoded = _JpegXlCodestreamDecoder.decode(encoded);
    return Image.fromRgba(
      width: decoded.width,
      height: decoded.height,
      bytes: decoded.toRgba8(),
      copy: false,
    );
  }

  /// Reconstructs the original JPEG bytes from transcoded JPEG XL data.
  ///
  /// Returns `null` when [encoded] does not contain JPEG reconstruction data.
  Uint8List? reconstructJpeg(Uint8List encoded) => _JpegXlCodestreamDecoder.reconstructJpeg(encoded);
}

/// Decodes JPEG XL images to raw pixels.
/// Handles lossless (Modular) and lossy (VarDCT) still images, animation,
/// splines, patches, reference frames and blending. Features that are not
/// yet implemented throw [JpegXlUnsupportedException] with the feature name;
/// malformed input throws another [JpegXlException] subtype.
final class _JpegXlCodestreamDecoder {
  /// Decodes [bytes] (bare codestream or ISOBMFF container).
  /// For animated inputs, decodes and returns the first visible frame.
  /// [targetWidth]/[targetHeight] request a reduced-resolution result — the
  /// output never exceeds that box (fit-within, aspect-preserving, never
  /// upscaled — the same contract as `ui.ResizeImage`). For a single-frame
  /// lossy (VarDCT) image with no patches, splines, noise or format-level
  /// upsampling, and a target no larger than the format's built-in 1:8-scale
  /// DC image, this decodes *only* the DC data — every AC coefficient is
  /// skipped, which is the bulk of decode time and memory for an oversized
  /// image — and box-filters that down to the exact target. Every other case
  /// (animated, Modular/lossless, patches/splines/noise present, or a target
  /// finer than 1:8 scale) decodes the image fully and then downsamples the
  /// result: always correct, just without the CPU/memory saving.
  static JpegXlDecodedImage decode(Uint8List bytes, {int? targetWidth, int? targetHeight}) {
    if (targetWidth != null || targetHeight != null) {
      final JpegXlDecodedImage? dcOnly = _tryDcOnlyDecode(bytes, targetWidth, targetHeight);
      if (dcOnly != null) {
        return dcOnly;
      }
    }
    final JpegXlDecodedImage full = _JpegXlDecoderState()._decode(bytes, allFrames: false).frames.first;
    return _downsampleIfNeeded(full, targetWidth, targetHeight);
  }

  /// Decodes all visible frames of [bytes].
  /// Still images produce a single frame with duration 0.
  static JpegXlDecodedAnimation decodeAnimation(Uint8List bytes) => _JpegXlDecoderState()._decode(bytes, allFrames: true);

  /// Reconstructs the original JPEG file from a JPEG-transcoded JXL, byte for
  /// byte, using its `jbrd` box. Returns null when [bytes] carry no JPEG
  /// reconstruction data (not a transcode). Throws [JpegXlUnsupportedException]
  /// for transcode variants not yet supported.
  static Uint8List? reconstructJpeg(Uint8List bytes) {
    final DemuxedStream demuxed = demuxContainer(bytes);
    final Uint8List? reconstructionData = demuxed.jpegReconstructionData;
    if (reconstructionData == null) {
      return null;
    }
    final state = _JpegXlDecoderState()..captureJpegReconstruction = true;
    state._decode(bytes, allFrames: false);
    final Frame? frame = state.capturedFrame;
    if (frame == null) {
      return null;
    }
    return reconstructJpegFromFrame(frame, reconstructionData);
  }

  /// Attempts the DC-only fast path; returns null (never throws) whenever it
  /// doesn't apply, so the caller falls back to a normal full decode — that
  /// full decode is the sole source of truth for real decode errors.
  static JpegXlDecodedImage? _tryDcOnlyDecode(Uint8List bytes, int? targetWidth, int? targetHeight) {
    try {
      final DemuxedStream demuxed = demuxContainer(bytes);
      final reader = BitReader(data: demuxed.codestream);
      final header = ImageHeader.read(reader: reader, level: demuxed.level);
      if (header.animation != null || header.extraChannels.isNotEmpty) {
        return null;
      }

      Uint8List? iccProfile;
      if (header.iccEncodedSize != null) {
        final Uint8List encoded = IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
        reader.zeroPadToByte();
        iccProfile = IccCodec.decompress(encoded);
      }
      if (header.previewSize != null) {
        final preview = Frame(globalReader: reader, globalMetadata: header);
        preview.readFrameHeader();
        preview.readTableOfContents();
      }

      final JpegXlDecodedImage? dcImage = _dcImageFor(reader, header, iccProfile);
      if (dcImage == null) {
        return null;
      }

      // Only usable when the caller's real target is no finer than the DC
      // image itself — otherwise this would silently under-deliver detail
      // that only a full AC decode can provide.
      final SizeDim orientedSize = header.orientedSize;
      final ({int height, int width}) resolved = resolveTargetSize(orientedSize.width, orientedSize.height, targetWidth: targetWidth, targetHeight: targetHeight);
      if (resolved.width == orientedSize.width && resolved.height == orientedSize.height) {
        return null; // no downscale actually requested
      }
      if (resolved.width > dcImage.width || resolved.height > dcImage.height) {
        return null; // finer than 1:8 — needs real AC data
      }
      return _downsampleIfNeeded(dcImage, targetWidth, targetHeight);
    } on JpegXlException {
      return null;
    } on RangeError {
      return null;
    }
  }

  /// Builds the 1:8 DC image for the DC-only fast path, or null when this file
  /// isn't a shape the fast path handles (caller then falls back to a full
  /// decode). Two shapes are handled, both cheap because JXL keeps DC (LF) and
  /// AC (HF) in separate bitstream sections:
  /// - a **plain single VarDCT frame**: decode only its LowFrequencyGlobal + LF groups
  ///   ([Frame.decodeLfOnly]) and assemble the DC ([buildDcImage]);
  /// - a **progressive-DC** file, whose DC lives in a separate level-1 LF frame
  ///   ahead of the main frame: decode that (small) LF frame and assemble its
  ///   rows ([buildDcImageFromRows]), skipping the main frame's AC entirely.
  ///   The main frame must itself be a plain full-canvas last VarDCT frame, so
  ///   its 1:8 DC represents the final image (the same discipline as the plain
  ///   case, just spread across two frames).
  static JpegXlDecodedImage? _dcImageFor(BitReader reader, ImageHeader header, Uint8List? iccProfile) {
    final first = Frame(globalReader: reader, globalMetadata: header);
    final FrameHeader firstFh = first.readFrameHeader();
    if (firstFh.type == FrameFlags.lowFrequencyFrame) {
      if (firstFh.lowFrequencyLevel != 1 || firstFh.encoding != FrameFlags.vardct || firstFh.upsampling != 1) {
        return null; // multi-level or non-VarDCT DC frame: not handled
      }
      first.readTableOfContents(); // FrameTableOfContents.read skips the reader past this frame's data
      final main = Frame(globalReader: reader, globalMetadata: header);
      final FrameHeader mainFh = main.readFrameHeader();
      if (mainFh.type != FrameFlags.regularFrame || mainFh.flags & FrameFlags.useLfFrame == 0 || !_isPlainVarDctFrame(mainFh, allowLfFrame: true)) {
        return null;
      }
      // The LF frame kept its own section bytes at readTableOfContents, so it decodes
      // independent of where the reader now sits (past the main header).
      first.decodeFrame();
      return buildDcImageFromRows(
        [for (var c = 0; c < 3; c++) first.buffer[c].floatRows],
        first.paddedFrameSize.height,
        first.paddedFrameSize.width,
        first.header.usesYcbcr,
        header,
        iccProfile,
        isPreview: false,
      );
    }
    if (firstFh.encoding == FrameFlags.modular) {
      return _modularLowResImageFor(first, firstFh, header, iccProfile);
    }
    if (!_dcOnlyEligible(firstFh)) {
      return null;
    }
    first.readTableOfContents();
    first.decodeLfOnly();
    return buildDcImage(first, header, iccProfile, isPreview: false);
  }

  /// Builds a ~1:8 image for a **Squeeze (responsive) lossless modular** frame
  /// without decoding its large full-resolution residual channels. Modular has
  /// no DC concept, but a responsive frame stores a hierarchical low-frequency
  /// pyramid (the `verticalShift/horizontalShift >= 3` Squeeze channels) in the global +
  /// LF-group sections, with the high-frequency detail in the pass groups.
  /// Decoding with [Frame.modularLowRes] zero-fills those pass-group channels,
  /// so the inverse Squeeze upsamples the low-frequency pyramid alone — a 1:8-
  /// accurate image (measured RMSE ~0.6 vs. a true box-downsample) for a
  /// fraction of the cost (measured ~3.7x faster on a 1024x1536 responsive
  /// file). Returns null (caller falls back to a full decode) for anything not
  /// safely handled: a non-plain frame, a non-Squeeze modular stream (its
  /// pass-group channels are the image, not residuals — zero-filling them is
  /// garbage), or colour that isn't plain integer (XYB/float/YCbCr).
  static JpegXlDecodedImage? _modularLowResImageFor(Frame first, FrameHeader fh, ImageHeader header, Uint8List? iccProfile) {
    if (!_plainModularFrame(fh)) {
      return null;
    }
    if (header.xybEncoded || header.bitDepth.usesFloatSamples || fh.usesYcbcr) {
      return null; // plain integer colour only; full decode handles the rest
    }
    first.readTableOfContents();
    first.decodeFrame(modularLowRes: true);
    if (!first.lowFrequencyGlobal.globalModularStream.usesSqueeze) {
      return null;
    }

    final int colors = header.colorChannelCount;
    final int visH = first.boundsHeight;
    final int visW = first.boundsWidth;
    final int dstH = ceilDiv(visH, 8);
    final int dstW = ceilDiv(visW, 8);
    final channels = <ImageBuffer>[for (var c = 0; c < colors; c++) boxDownsample(_cropVisible(first.buffer[c], visH, visW), dstW, dstH)];
    final List<ImageBuffer> oriented = [for (final ch in channels) transposeBuffer(ch, header.orientation)];
    return JpegXlDecodedImage.scaled(header: header, channels: oriented, iccProfile: iccProfile, width: oriented[0].width, height: oriented[0].height);
  }

  /// Copies the visible top-left [visH]x[visW] region out of a (possibly
  /// group-padded) frame buffer, so the box-downsample below never averages in
  /// padding pixels. A no-op (returns [src]) when there's no padding.
  static ImageBuffer _cropVisible(ImageBuffer src, int visH, int visW) {
    if (src.height == visH && src.width == visW) {
      return src;
    }
    final dst = src.isFloat ? ImageBuffer.float32(height: visH, width: visW) : ImageBuffer.int32(height: visH, width: visW);
    if (src.isFloat) {
      for (var y = 0; y < visH; y++) {
        dst.floatRows[y].setRange(0, visW, src.floatRows[y]);
      }
    } else {
      for (var y = 0; y < visH; y++) {
        dst.intRows[y].setRange(0, visW, src.intRows[y]);
      }
    }
    return dst;
  }

  /// Whether [fh] is a plain, last, full-canvas modular frame with none of the
  /// features (patches/splines/noise/a separate LF frame/format-level
  /// upsampling) the low-res Squeeze path doesn't account for.
  static bool _plainModularFrame(FrameHeader fh) {
    const int bad = FrameFlags.noise | FrameFlags.patches | FrameFlags.splines | FrameFlags.useLfFrame;
    return fh.encoding == FrameFlags.modular &&
        fh.type == FrameFlags.regularFrame &&
        fh.isLast &&
        fh.coversFullCanvas &&
        fh.upsampling == 1 &&
        fh.extraChannelUpsampling.every((u) => u == 1) &&
        fh.flags & bad == 0;
  }

  /// Whether [fh] is a plain single-frame VarDCT frame with none of the
  /// features (patches/splines/noise/a separate LF frame/format-level
  /// upsampling) that the DC-only path doesn't account for.
  static bool _dcOnlyEligible(FrameHeader fh) => fh.type == FrameFlags.regularFrame && _isPlainVarDctFrame(fh, allowLfFrame: false);

  /// The shared "plain VarDCT frame" predicate: last, full-canvas, no
  /// format-level upsampling, and none of the patches/splines/noise features
  /// the DC path can't represent. [allowLfFrame] keeps a progressive-DC main
  /// frame's `useLfFrame` flag from disqualifying it (that flag is expected
  /// there); the plain single-frame path forbids it.
  static bool _isPlainVarDctFrame(FrameHeader fh, {required bool allowLfFrame}) {
    const int base = FrameFlags.noise | FrameFlags.patches | FrameFlags.splines;
    final int bad = allowLfFrame ? base : base | FrameFlags.useLfFrame;
    return fh.encoding == FrameFlags.vardct && fh.isLast && fh.coversFullCanvas && fh.upsampling == 1 && fh.extraChannelUpsampling.every((u) => u == 1) && fh.flags & bad == 0;
  }

  /// Downsamples [image] to fit [targetWidth]/[targetHeight] if it doesn't
  /// already (a no-op, returning [image] itself, when it's already within
  /// that box — this never upscales).
  static JpegXlDecodedImage _downsampleIfNeeded(JpegXlDecodedImage image, int? targetWidth, int? targetHeight) {
    final ({int height, int width}) target = resolveTargetSize(image.width, image.height, targetWidth: targetWidth, targetHeight: targetHeight);
    if (target.width == image.width && target.height == image.height) {
      return image;
    }
    final List<ImageBuffer> resized = [for (final channel in image.channels) boxDownsample(channel, target.width, target.height)];
    return JpegXlDecodedImage.scaled(header: image.header, channels: resized, iccProfile: image.iccProfile, width: target.width, height: target.height);
  }
}

/// Mutable state shared while decoding one JPEG XL codestream.
final class _JpegXlDecoderState {
  /// Parsed image header consumed by the JPEG XL decoder.
  late ImageHeader imageHeader;

  /// Four reference-frame slots addressable by patches and blending metadata.
  final List<List<ImageBuffer?>?> _referenceFrames = List<List<ImageBuffer?>?>.filled(4, null);

  /// Progressive low-frequency buffers indexed by their resolution level.
  final List<List<ImageBuffer>?> _lowFrequencyBuffersByLevel = List.filled(5, null);

  /// Canvas onto which visible frames are composited.
  List<ImageBuffer?>? _canvas;

  /// Number of consecutive visible frames decoded so far.
  int _visibleFrameCount = 0;

  /// Number of consecutive reference-only frames decoded so far.
  int _invisibleFrameCount = 0;

  /// JPEG reconstruction: when set, the first regular frame captures quantized
  /// coefficients and is retained in [capturedFrame].
  bool captureJpegReconstruction = false;

  /// First regular frame retained for JPEG bitstream reconstruction.
  Frame? capturedFrame;

  /// Visible images produced in presentation order.
  final List<JpegXlDecodedImage> decodedFrames = [];

  /// Presentation duration of every entry in [decodedFrames].
  final List<int> frameDurations = [];

  /// Presentation timecode of every entry in [decodedFrames].
  final List<int> frameTimecodes = [];

  /// Creates fresh state for one decode operation.
  _JpegXlDecoderState();

  /// Decodes the available JPEG XL data.
  JpegXlDecodedAnimation _decode(Uint8List bytes, {required bool allFrames}) {
    final DemuxedStream demuxed = demuxContainer(bytes);
    final reader = BitReader(data: demuxed.codestream);
    imageHeader = ImageHeader.read(reader: reader, level: demuxed.level);
    _validateImageSize(imageHeader);

    Uint8List? iccProfile;
    if (imageHeader.iccEncodedSize != null) {
      final Uint8List encoded = IccCodec.readEncodedStream(reader, imageHeader.iccEncodedSize!);
      reader.zeroPadToByte();
      iccProfile = IccCodec.decompress(encoded);
    }

    if (imageHeader.previewSize != null) {
      // Skip the preview frame entirely (readTableOfContents advances past the data).
      final preview = Frame(globalReader: reader, globalMetadata: imageHeader);
      preview.readFrameHeader();
      preview.readTableOfContents();
    }

    var frameCount = 0;
    while (true) {
      if (++frameCount > JpegXlLimits.maxFrames) {
        throw const JpegXlInvalidBitstreamException(message: 'too many frames');
      }
      final frame = Frame(globalReader: reader, globalMetadata: imageHeader);
      final FrameHeader header = frame.readFrameHeader();
      frame.readTableOfContents();

      if (header.flags & FrameFlags.useLfFrame != 0 && _lowFrequencyBuffersByLevel[header.lowFrequencyLevel] == null) {
        throw const JpegXlInvalidBitstreamException(message: 'LF level too large');
      }
      if (const bool.fromEnvironment('jxl.framedebug')) {
        // ignore: avoid_print
        print(
          'frame: type=${header.type} dur=${header.duration} '
          'x0=${header.x0} y0=${header.y0} ${header.width}x${header.height} '
          'saveRef=${header.referenceSlot} beforeCT=${header.saveBeforeColorTransform} '
          'blend=(mode=${header.blendingInfo.mode} '
          'src=${header.blendingInfo.source} '
          'alpha=${header.blendingInfo.alphaChannel}) isLast=${header.isLast}',
        );
      }
      if (captureJpegReconstruction && capturedFrame == null) {
        frame.captureJpegReconstruction = true;
      }
      frame.decodeFrame(lowFrequencyFrame: _lowFrequencyBuffersByLevel[header.lowFrequencyLevel]);
      if (captureJpegReconstruction && capturedFrame == null && frame.captureJpegReconstruction) {
        capturedFrame = frame;
      }
      if (header.lowFrequencyLevel > 0) {
        _lowFrequencyBuffersByLevel[header.lowFrequencyLevel - 1] = frame.buffer;
      }
      if (header.type == FrameFlags.lowFrequencyFrame) {
        continue;
      }

      final bool save = (header.referenceSlot != 0 || header.duration == 0) && !header.isLast && header.type != FrameFlags.lowFrequencyFrame;
      if (frame.isVisible) {
        _visibleFrameCount++;
        _invisibleFrameCount = 0;
      } else {
        _invisibleFrameCount++;
      }
      upsampleFrame(frame);
      final List<List<Float32List>>? noiseBuffer = initializeNoise(frame, _visibleFrameCount, _invisibleFrameCount);
      if (save && header.saveBeforeColorTransform) {
        _referenceFrames[header.referenceSlot] = [for (final b in frame.buffer) ImageBuffer.copy(other: b)];
      }
      _applyPatches(frame);
      renderSplines(frame);
      synthesizeNoise(frame, noiseBuffer);
      _performColorTransforms(frame);

      if (header.type == FrameFlags.regularFrame || header.type == FrameFlags.skipProgressive) {
        _canvas ??= List<ImageBuffer?>.filled(imageHeader.colorChannelCount + imageHeader.extraChannels.length, null);
        final List<ImageBuffer?> canvas = _canvas!;
        if (canvas[0] == null) {
          for (var c = 0; c < canvas.length; c++) {
            canvas[c] = frame.buffer[0].isInt
                ? ImageBuffer.int32(height: imageHeader.size.height, width: imageHeader.size.width)
                : ImageBuffer.float32(height: imageHeader.size.height, width: imageHeader.size.width);
          }
        }
        // If a reference aliases the canvas (and won't be overwritten),
        // detach before blending mutates it.
        var aliased = false;
        for (var i = 0; i < 4; i++) {
          if (identical(_referenceFrames[i], _canvas) && i != header.referenceSlot) {
            aliased = true;
            break;
          }
        }
        if (aliased) {
          _canvas = [for (final b in _canvas!) ImageBuffer.copy(other: b!)];
        }
        _blendFrame(_canvas!, frame);
      }
      if (save && !header.saveBeforeColorTransform) {
        _referenceFrames[header.referenceSlot] = _canvas;
      }

      if (allFrames && frame.isVisible) {
        // Snapshot the canvas: later frames keep blending onto it, so
        // finalize a copy (except for the last frame).
        decodedFrames.add(_finalizeCanvas(iccProfile, copy: !header.isLast));
        frameDurations.add(header.duration);
        frameTimecodes.add(header.timecode);
      }
      if (allFrames ? header.isLast : header.isLast || header.duration != 0) {
        break;
      }
    }

    if (!allFrames) {
      decodedFrames.add(_finalizeCanvas(iccProfile, copy: false));
      frameDurations.add(0);
      frameTimecodes.add(0);
    }
    final AnimationHeader? animation = imageHeader.animation;
    return JpegXlDecodedAnimation.internal(
      frames: decodedFrames,
      frameDurations: frameDurations,
      frameTimecodes: frameTimecodes,
      ticksPerSecondNumerator: animation?.ticksPerSecondNumerator ?? 1,
      ticksPerSecondDenominator: animation?.ticksPerSecondDenominator ?? 1,
      loopCount: animation?.loopCount ?? 0,
    );
  }

  /// Rejects dimensions whose planes would exceed the decoder allocation limit.
  static void _validateImageSize(ImageHeader header) {
    final int w = header.size.width;
    final int h = header.size.height;
    if (w <= 0 || h <= 0 || h > JpegXlLimits.maxPlanePixels ~/ w) {
      throw const JpegXlInvalidBitstreamException(message: 'image size exceeds JpegXlLimits.maxPlanePixels');
    }
  }

  /// Applies output transforms and orientation to the composited canvas.
  JpegXlDecodedImage _finalizeCanvas(Uint8List? iccProfile, {required bool copy}) {
    final List<ImageBuffer?>? canvas = _canvas;
    if (canvas == null || canvas[0] == null) {
      throw const JpegXlInvalidBitstreamException(message: 'no visible frame decoded');
    }
    final List<ImageBuffer?> planes = copy ? [for (final b in canvas) ImageBuffer.copy(other: b!)] : canvas;
    // Modular (non-XYB) float-sample channels are still holding their raw
    // decoded integers at this point — the packed sign/exponent/mantissa
    // bits, not a value to scale (see [ImageBuffer.reconstructFloatSamples]).
    // Float samples and XYB encoding are mutually exclusive in the format,
    // so this never touches a channel the transfer-function step below
    // also needs. Not verified against blending/patches/splines combined
    // with float samples — only the plain single-frame case.
    final int colors = imageHeader.colorChannelCount;
    for (var c = 0; c < colors; c++) {
      final BitDepthHeader bd = imageHeader.bitDepth;
      if (bd.usesFloatSamples) {
        planes[c]!.reconstructFloatSamples(bd.bitsPerSample, bd.exponentBits);
      }
    }
    for (var i = 0; i < imageHeader.extraChannels.length; i++) {
      final BitDepthHeader bd = imageHeader.extraChannels[i].bitDepth;
      if (bd.usesFloatSamples) {
        planes[colors + i]!.reconstructFloatSamples(bd.bitsPerSample, bd.exponentBits);
      }
    }
    // XYB frames come out of the color transform in linear RGB. Convert to the
    // output encoding: for a file whose colour is described by a matrix/TRC RGB
    // ICC profile, apply that profile (linear -> profile device values, the
    // representation the conformance reference uses); otherwise apply the
    // image's tagged transfer function. See color/icc_transform.dart.
    if (imageHeader.xybEncoded) {
      final IccRgbOutputTransform? icc = imageHeader.colorEncoding.useIccProfile && iccProfile != null && imageHeader.colorChannelCount >= 3 ? IccRgbOutputTransform.tryParse(iccProfile) : null;
      if (icc != null) {
        icc.apply(planes[0]!.floatRows, planes[1]!.floatRows, planes[2]!.floatRows);
      } else {
        final TransferFunction transferFunction = TransferFunction.forTransfer(imageHeader.colorEncoding.transferFunction);
        for (var c = 0; c < imageHeader.colorChannelCount && c < 3; c++) {
          for (final Float32List row in planes[c]!.floatRows) {
            for (var i = 0; i < row.length; i++) {
              row[i] = transferFunction.fromLinear(row[i]);
            }
          }
        }
      }
    }
    _compositeSpotColors(planes);
    final List<ImageBuffer> oriented = [for (final plane in planes) transposeBuffer(plane!, imageHeader.orientation)];
    return JpegXlDecodedImage.internal(header: imageHeader, channels: oriented, iccProfile: iccProfile);
  }

  /// Composites spot-colour extra channels onto the colour channels:
  /// `out = mix * spotRGB + (1 - mix) * out`, `mix = spotValue * solidity`, in
  /// extra-channel order (each spot channel's own `red`/`green`/`blue`/
  /// `solidity` from the header). Runs on the final output-encoded values
  /// (device 0..1) — verified against the `spot` conformance case, which is
  /// Modular so this is the signal/device domain the spot colours are defined
  /// in. (For an XYB image this therefore blends in the output-encoded domain,
  /// not linear light; no conformance case exercises XYB + spot colour.)
  /// Channels stored subsampled (`dimensionShift > 0`) are skipped — none of the
  /// conformance spot channels use it, and blending a size-mismatched plane
  /// would be worse than leaving it un-applied.
  void _compositeSpotColors(List<ImageBuffer?> planes) {
    final int colors = imageHeader.colorChannelCount;
    if (colors < 3) {
      return; // spot colour is defined against RGB
    }
    for (var i = 0; i < imageHeader.extraChannels.length; i++) {
      final ExtraChannelInfo ec = imageHeader.extraChannels[i];
      if (ec.type != ExtraChannelType.spotColor) {
        continue;
      }
      final ImageBuffer? spot = planes[colors + i];
      final ImageBuffer r = planes[0]!;
      final ImageBuffer g = planes[1]!;
      final ImageBuffer b = planes[2]!;
      if (spot == null || spot.width != r.width || spot.height != r.height) {
        continue;
      }
      final List<double> srgb = [ec.red, ec.green, ec.blue];
      final double solidity = ec.solidity;
      final double spotMax = ec.bitDepth.maxValue.toDouble();
      final int colorMax = imageHeader.bitDepth.maxValue;
      final double colorMaxF = colorMax.toDouble();
      final cp = [r, g, b];
      for (var y = 0; y < r.height; y++) {
        for (var x = 0; x < r.width; x++) {
          final double sv = spot.isInt ? spot.intRows[y][x] / spotMax : spot.floatRows[y][x];
          final double mix = sv * solidity;
          if (mix == 0) {
            continue;
          }
          for (var c = 0; c < 3; c++) {
            final ImageBuffer plane = cp[c];
            if (plane.isInt) {
              final double base = plane.intRows[y][x] / colorMaxF;
              final double v = mix * srgb[c] + (1 - mix) * base;
              plane.intRows[y][x] = (v * colorMaxF + 0.5).floor().clamp(0, colorMax);
            } else {
              final double base = plane.floatRows[y][x];
              plane.floatRows[y][x] = mix * srgb[c] + (1 - mix) * base;
            }
          }
        }
      }
    }
  }

  /// Applies the XYB inverse (into linear RGB with the image's primaries)
  /// and/or the YCbCr transform in place on the frame's color channels.
  void _performColorTransforms(Frame frame) {
    if (!imageHeader.xybEncoded && !frame.header.usesYcbcr) {
      return;
    }
    for (var c = 0; c < 3; c++) {
      frame.buffer[c].castToFloat(imageHeader.bitDepth.bitsPerSample);
    }
    final List<List<Float32List>> rows = [for (var c = 0; c < 3; c++) frame.buffer[c].floatRows];
    if (imageHeader.xybEncoded) {
      final ColorEncodingBundle bundle = imageHeader.colorEncoding;
      final OpsinInverseMatrix matrix = imageHeader.opsinInverseMatrix.getMatrix(bundle.prim, bundle.white);
      matrix.invertXyb(frame.buffer[0].floatRows, frame.buffer[1].floatRows, frame.buffer[2].floatRows, imageHeader.toneMapping.intensityTarget);
    }
    if (frame.header.usesYcbcr) {
      final int height = frame.buffer[0].height;
      final int width = frame.buffer[0].width;
      for (var y = 0; y < height; y++) {
        final Float32List cbRow = rows[0][y];
        final Float32List yRow = rows[1][y];
        final Float32List crRow = rows[2][y];
        for (var x = 0; x < width; x++) {
          final double cb = cbRow[x];
          final double yh = yRow[x] + 0.50196078431372549019;
          final double cr = crRow[x];
          cbRow[x] = yh + 1.402 * cr;
          yRow[x] = yh - 0.34413628620102214650 * cb - 0.71413628620102214650 * cr;
          crRow[x] = yh + 1.772 * cb;
        }
      }
    }
  }

  /// Applies every reference-frame patch declared by [frame].
  void _applyPatches(Frame frame) {
    final FrameHeader header = frame.header;
    final int colorChannels = imageHeader.colorChannelCount;
    final int extraChannels = imageHeader.extraChannels.length;
    for (final Patch patch in frame.lowFrequencyGlobal.patches) {
      if (patch.referenceIndex > 3) {
        throw const JpegXlInvalidBitstreamException(message: 'patch referenceIndex out of range');
      }
      final List<ImageBuffer?>? refBuffers = _referenceFrames[patch.referenceIndex];
      // Referencing a nonexistent frame is legal; the patch is a no-op.
      if (refBuffers == null) {
        continue;
      }
      final ImageBuffer refBuffer0 = refBuffers[0]!;
      if (patch.y + patch.height > refBuffer0.height || patch.x + patch.width > refBuffer0.width) {
        throw const JpegXlInvalidBitstreamException(message: 'patch too large');
      }
      for (var j = 0; j < patch.positionsX.length; j++) {
        final int y0 = patch.positionsY[j];
        final int x0 = patch.positionsX[j];
        if (y0 < 0 || x0 < 0) {
          throw const JpegXlInvalidBitstreamException(message: 'patch out of bounds');
        }
        if (patch.height + y0 > frame.boundsHeight || patch.width + x0 > frame.boundsWidth) {
          throw const JpegXlInvalidBitstreamException(message: 'patch out of bounds');
        }
        for (var d = 0; d < colorChannels + extraChannels; d++) {
          final int c = d < colorChannels ? 0 : d - colorChannels + 1;
          final BlendingInfo info = patch.blendingInfos[j][c];
          if (info.mode == 0) {
            continue;
          }
          if (info.mode > 3 && header.upsampling > 1 && c > 0 && header.extraChannelUpsampling[c - 1] << imageHeader.extraChannels[c - 1].dimensionShift != header.upsampling) {
            throw const JpegXlInvalidBitstreamException(message: 'alpha upsampling mismatch in patch');
          }
          blendBuffers(
            imageHeader: imageHeader,
            canvas: frame.buffer[d],
            frameBuffers: frame.buffer,
            refBuffers: refBuffers,
            patchY: y0,
            patchX: x0,
            frameY: y0,
            frameX: x0,
            refY: patch.y,
            refX: patch.x,
            blendHeight: patch.height,
            blendWidth: patch.width,
            idx: d,
            srcFrame: frame,
            info: info,
            isPatch: true,
          );
        }
      }
    }
  }

  /// Composites [frame] onto [canvas] using its per-channel blend settings.
  void _blendFrame(List<ImageBuffer?> canvas, Frame frame) {
    final int width = imageHeader.size.width;
    final int height = imageHeader.size.height;
    final FrameHeader header = frame.header;
    final int patchStartY = header.y0.clamp(0, height);
    final int patchStartX = header.x0.clamp(0, width);
    final int frameOffsetY = patchStartY - header.y0;
    final int frameOffsetX = patchStartX - header.x0;
    final int lowerY = header.y0 + frame.boundsHeight;
    final int lowerX = header.x0 + frame.boundsWidth;
    final int blendHeight = (lowerY < height ? lowerY : height) - patchStartY;
    final int blendWidth = (lowerX < width ? lowerX : width) - patchStartX;
    final int colors = imageHeader.colorChannelCount;
    final bool fullCover = patchStartY == 0 && patchStartX == 0 && blendHeight == height && blendWidth == width;
    for (var c = 0; c < canvas.length; c++) {
      final BlendingInfo info = c >= colors ? header.ecBlendingInfo[c - colors] : header.blendingInfo;
      // The canvas outside the frame's crop is defined by the blending
      // source reference (zeros when that slot is empty), not by whatever
      // the canvas held before. When the reference aliases the canvas the
      // copy is a no-op.
      if (!fullCover && !identical(_referenceFrames[info.source], canvas)) {
        _fillFromReference(canvas[c]!, _referenceFrames[info.source]?[c]);
      }
      blendBuffers(
        imageHeader: imageHeader,
        canvas: canvas[c]!,
        frameBuffers: frame.buffer,
        refBuffers: _referenceFrames[info.source],
        patchY: patchStartY,
        patchX: patchStartX,
        frameY: frameOffsetY,
        frameX: frameOffsetX,
        refY: patchStartY,
        refX: patchStartX,
        blendHeight: blendHeight,
        blendWidth: blendWidth,
        idx: c,
        srcFrame: frame,
        info: info,
        isPatch: false,
      );
    }
  }

  /// Replaces [destination] with [source], or clears it when no source exists.
  void _fillFromReference(ImageBuffer destination, ImageBuffer? source) {
    if (source == null) {
      if (destination.isInt) {
        for (final Int32List row in destination.intRows) {
          row.fillRange(0, row.length, 0);
        }
      } else {
        for (final Float32List row in destination.floatRows) {
          row.fillRange(0, row.length, 0);
        }
      }
      return;
    }
    if (destination.isInt != source.isInt) {
      final int bits = imageHeader.bitDepth.bitsPerSample;
      destination.castToFloat(bits);
      source.castToFloat(bits);
    }
    final int height = destination.height < source.height ? destination.height : source.height;
    final int width = destination.width < source.width ? destination.width : source.width;
    if (destination.isInt) {
      for (var y = 0; y < height; y++) {
        destination.intRows[y].setRange(0, width, source.intRows[y]);
      }
    } else {
      for (var y = 0; y < height; y++) {
        destination.floatRows[y].setRange(0, width, source.floatRows[y]);
      }
    }
  }
}
