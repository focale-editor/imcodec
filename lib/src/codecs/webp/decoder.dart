part of '../webp.dart';

/// Decodes static and first-frame WebP images synchronously.
final class WebPDecoder extends RasterDecoder {
  /// Creates a WebP decoder.
  const WebPDecoder();

  /// Decodes VP8, VP8 with alpha, or VP8L pixels to straight RGBA.
  @override
  Image decode(Uint8List bytes, {required int maxPixels}) {
    if (bytes.length < 20 || _fourCharacterCode(bytes, 0) != 'RIFF' || _fourCharacterCode(bytes, 8) != 'WEBP') {
      throw const ImageCodecException('Invalid WebP RIFF header');
    }
    final int declaredLength = _readUint32(bytes, 4) + 8;
    if (declaredLength > bytes.length || declaredLength < 20) {
      throw const ImageCodecException('The WebP RIFF payload is truncated');
    }
    final _WebPContainer container = _readChunks(bytes, 12, declaredLength);
    final _WebPImagePayload payload =
        container.payload ?? (container.animationFrame == null ? throw const ImageCodecException('WebP contains no decodable image payload') : _readAnimationPayload(bytes, container.animationFrame!));
    final int width = _payloadWidth(payload);
    final int height = _payloadHeight(payload);
    _checkDimensions(width, height, maxPixels: maxPixels);

    final _WebPDecodingInfo information = _WebPDecodingInfo()
      ..width = width
      ..height = height
      ..alphaData = payload.alpha
      ..alphaSize = payload.alpha?.length ?? 0;
    final Image? decoded = switch (payload.type) {
      _WebPPayloadType.lossless => _Vp8LosslessDecoder(input: payload.data, information: information).decode(),
      _WebPPayloadType.lossy => _Vp8Decoder(
        input: payload.data,
        information: information,
      ).decode(),
    };
    if (decoded == null) {
      throw const ImageCodecException('Could not decode the WebP pixel stream');
    }
    final _WebPAnimationFrame? frame = container.animationFrame;
    if (frame == null) {
      return decoded;
    }
    if (decoded.width != frame.width || decoded.height != frame.height) {
      throw const ImageCodecException('WebP animation frame dimensions do not match its pixel payload');
    }
    final int canvasWidth = container.canvasWidth ?? width;
    final int canvasHeight = container.canvasHeight ?? height;
    _checkDimensions(canvasWidth, canvasHeight, maxPixels: maxPixels);
    if (frame.x + decoded.width > canvasWidth || frame.y + decoded.height > canvasHeight) {
      throw const ImageCodecException('WebP animation frame exceeds its canvas');
    }
    final Image canvas = Image(width: canvasWidth, height: canvasHeight);
    for (int y = 0; y < decoded.height; y++) {
      final int source = y * decoded.width * 4;
      final int destination = ((frame.y + y) * canvasWidth + frame.x) * 4;
      canvas.bytes.setRange(destination, destination + decoded.width * 4, decoded.bytes, source);
    }
    return canvas;
  }

  /// Parses top-level RIFF chunks needed for the default image or first frame.
  _WebPContainer _readChunks(Uint8List bytes, int start, int end) {
    _WebPImagePayload? payload;
    _WebPBuffer? alpha;
    _WebPAnimationFrame? animationFrame;
    int? canvasWidth;
    int? canvasHeight;
    int position = start;
    while (position < end) {
      if (end - position < 8) {
        throw const ImageCodecException('The WebP chunk header is truncated');
      }
      final String type = _fourCharacterCode(bytes, position);
      final int length = _readUint32(bytes, position + 4);
      final int dataOffset = position + 8;
      final int paddedLength = length + (length & 1);
      if (length > end - dataOffset || paddedLength > end - dataOffset) {
        throw const ImageCodecException('The WebP chunk payload is truncated');
      }
      switch (type) {
        case 'VP8X':
          if (length != 10) {
            throw const ImageCodecException('Invalid WebP extended header');
          }
          canvasWidth = _readUint24(bytes, dataOffset + 4) + 1;
          canvasHeight = _readUint24(bytes, dataOffset + 7) + 1;
        case 'ALPH':
          alpha = _WebPBuffer(data: bytes, offset: dataOffset, length: length);
        case 'VP8 ':
          payload ??= _WebPImagePayload(
            type: _WebPPayloadType.lossy,
            data: _WebPBuffer(data: bytes, offset: dataOffset, length: length),
            alpha: alpha,
          );
        case 'VP8L':
          payload ??= _WebPImagePayload(
            type: _WebPPayloadType.lossless,
            data: _WebPBuffer(data: bytes, offset: dataOffset, length: length),
          );
        case 'ANMF':
          animationFrame ??= _readAnimationFrame(bytes, dataOffset, length);
        default:
          break;
      }
      position = dataOffset + paddedLength;
    }
    return _WebPContainer(
      payload: payload,
      animationFrame: animationFrame,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
    );
  }

  /// Reads the fixed header of the first animation frame.
  _WebPAnimationFrame _readAnimationFrame(Uint8List bytes, int offset, int length) {
    if (length < 16) {
      throw const ImageCodecException('The WebP animation frame header is truncated');
    }
    return _WebPAnimationFrame(
      x: _readUint24(bytes, offset) * 2,
      y: _readUint24(bytes, offset + 3) * 2,
      width: _readUint24(bytes, offset + 6) + 1,
      height: _readUint24(bytes, offset + 9) + 1,
      payloadOffset: offset + 16,
      payloadLength: length - 16,
    );
  }

  /// Parses the nested chunks carried by an animation frame.
  _WebPImagePayload _readAnimationPayload(Uint8List bytes, _WebPAnimationFrame frame) {
    final _WebPContainer nested = _readChunks(bytes, frame.payloadOffset, frame.payloadOffset + frame.payloadLength);
    return nested.payload ?? (throw const ImageCodecException('WebP animation frame contains no image payload'));
  }

  /// Reads encoded dimensions without allocating decoder buffers.
  int _payloadWidth(_WebPImagePayload payload) {
    if (payload.type == _WebPPayloadType.lossless) {
      if (payload.data.length < 5 || payload.data[0] != 0x2f) {
        throw const ImageCodecException('Invalid VP8L header');
      }
      return 1 + (payload.data[1] | ((payload.data[2] & 0x3f) << 8));
    }
    if (payload.data.length < 10 || payload.data[3] != 0x9d || payload.data[4] != 0x01 || payload.data[5] != 0x2a) {
      throw const ImageCodecException('Invalid VP8 key-frame header');
    }
    return (payload.data[6] | (payload.data[7] << 8)) & 0x3fff;
  }

  /// Reads encoded height without allocating decoder buffers.
  int _payloadHeight(_WebPImagePayload payload) {
    if (payload.type == _WebPPayloadType.lossless) {
      return 1 + (((payload.data[2] >>> 6) | (payload.data[3] << 2) | ((payload.data[4] & 0x0f) << 10)) & 0x3fff);
    }
    return (payload.data[8] | (payload.data[9] << 8)) & 0x3fff;
  }

  /// Rejects invalid dimensions before allocating decoded pixels.
  void _checkDimensions(int width, int height, {required int maxPixels}) {
    if (width < 1 || height < 1) {
      throw const ImageCodecException('WebP dimensions must be positive and non-zero');
    }
    final int pixelCount = width * height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
  }

  /// Reads an ASCII four-character code.
  String _fourCharacterCode(Uint8List bytes, int offset) => String.fromCharCodes(Uint8List.sublistView(bytes, offset, offset + 4));

  /// Reads a little-endian 24-bit integer.
  int _readUint24(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

  /// Reads a little-endian 32-bit integer.
  int _readUint32(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
}

/// Distinguishes lossy VP8 from lossless VP8L payloads.
enum _WebPPayloadType {
  /// Lossy VP8 payload.
  lossy,

  /// Lossless VP8L payload.
  lossless,
}

/// Stores one compressed pixel payload and its optional alpha chunk.
final class _WebPImagePayload {
  /// Compression format carried by [data].
  final _WebPPayloadType type;

  /// Bounded compressed payload.
  final _WebPBuffer data;

  /// Optional alpha payload paired with lossy VP8 data.
  final _WebPBuffer? alpha;

  /// Creates a compressed payload description.
  const _WebPImagePayload({
    required this.type,
    required this.data,
    this.alpha,
  });
}

/// Stores the first useful image and animation metadata found in a container.
final class _WebPContainer {
  /// Top-level static image payload.
  final _WebPImagePayload? payload;

  /// First animation frame when no static payload exists.
  final _WebPAnimationFrame? animationFrame;

  /// Extended canvas width.
  final int? canvasWidth;

  /// Extended canvas height.
  final int? canvasHeight;

  /// Creates parsed container state.
  const _WebPContainer({
    required this.payload,
    required this.animationFrame,
    required this.canvasWidth,
    required this.canvasHeight,
  });
}

/// Stores the geometry and nested payload range of an animation frame.
final class _WebPAnimationFrame {
  /// Horizontal frame offset.
  final int x;

  /// Vertical frame offset.
  final int y;

  /// Declared frame width.
  final int width;

  /// Declared frame height.
  final int height;

  /// Absolute offset of nested image chunks.
  final int payloadOffset;

  /// Number of bytes occupied by nested image chunks.
  final int payloadLength;

  /// Creates parsed animation-frame metadata.
  const _WebPAnimationFrame({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.payloadOffset,
    required this.payloadLength,
  });
}
