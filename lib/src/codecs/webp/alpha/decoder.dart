part of '../../webp.dart';

/// Decodes the alpha plane paired with a lossy VP8 image.
final class _WebPAlphaDecoder {
  /// Identifier for an uncompressed alpha plane.
  static const int _uncompressedMethod = 0;

  /// Identifier for a VP8L-compressed alpha plane.
  static const int _losslessMethod = 1;

  /// Identifier for the optional alpha-level preprocessing step.
  static const int _preprocessedLevels = 1;

  /// Encoded alpha bytes positioned immediately after their control byte.
  final _WebPBuffer _input;

  /// Alpha-plane width in pixels.
  final int _width;

  /// Alpha-plane height in pixels.
  final int _height;

  /// Compression method read from the control byte.
  late final int _method;

  /// Predictive filter read from the control byte.
  late final int _filter;

  /// Preprocessing method read from the control byte.
  late final int _preprocessing;

  /// Whether the header and compressed payload are supported.
  late final bool _isValid;

  /// Lossless decoder used for compressed alpha data.
  late final _Vp8LosslessDecoder _losslessDecoder;

  /// Whether the optimized one-byte lossless path can be used.
  bool _usesByteDecoder = false;

  /// Whether every requested alpha row has been decoded.
  bool _isDecoded = false;

  /// Creates an alpha decoder and parses its control byte.
  _WebPAlphaDecoder({
    required this._input,
    required this._width,
    required this._height,
  }) {
    final int control = _input.readByte();
    _method = control & 0x03;
    _filter = (control >> 2) & 0x03;
    _preprocessing = (control >> 4) & 0x03;
    final int reserved = (control >> 6) & 0x03;
    _isValid =
        reserved == 0 &&
        _method >= _uncompressedMethod &&
        _method <= _losslessMethod &&
        _filter < _WebPAlphaFilters.filterCount &&
        _preprocessing <= _preprocessedLevels &&
        (_method != _uncompressedMethod || _input.length >= _width * _height) &&
        (_method != _losslessMethod || _decodeLosslessHeader());
  }

  /// Whether the encoded alpha payload has a supported header.
  bool get isValid => _isValid;

  /// Whether all alpha rows have been decoded.
  bool get isDecoded => _isDecoded;

  /// Decodes [rowCount] rows beginning at [row] into [output].
  bool decode(int row, int rowCount, Uint8List output) {
    if (!_isValid || row < 0 || rowCount < 0 || row + rowCount > _height) {
      return false;
    }

    if (_method == _uncompressedMethod) {
      final int offset = row * _width;
      final int pixelCount = rowCount * _width;
      output.setRange(offset, offset + pixelCount, _input.buffer, _input.offset + offset);
    } else if (!_decodeLosslessRows(row + rowCount, output)) {
      return false;
    }

    final void Function(int, int, int, int, int, Uint8List)? unfilter = _WebPAlphaFilters.unfilters[_filter];
    unfilter?.call(_width, _height, _width, row, rowCount, output);

    if (_preprocessing == _preprocessedLevels && !_validatePreprocessedRows(row, rowCount)) {
      return false;
    }
    if (row + rowCount == _height) {
      _isDecoded = true;
    }
    return true;
  }

  /// Decodes lossless alpha rows up to [endRow].
  bool _decodeLosslessRows(int endRow, Uint8List output) {
    _losslessDecoder._opaque = output;
    return _usesByteDecoder
        ? _losslessDecoder._decodeAlphaData(_width, _height, endRow)
        : _losslessDecoder._decodeImageData(
            _losslessDecoder._pixels!,
            _width,
            _height,
            endRow,
            _losslessDecoder._extractAlphaRows,
          );
  }

  /// Initializes the VP8L stream used by compressed alpha data.
  bool _decodeLosslessHeader() {
    final _WebPDecodingInfo information = _WebPDecodingInfo()
      ..width = _width
      ..height = _height;
    _losslessDecoder = _Vp8LosslessDecoder(
      input: _input,
      information: information,
    ).._ioWidth = _width;

    _losslessDecoder._decodeImageStream(_width, _height, true);
    _usesByteDecoder = _losslessDecoder._transforms.length == 1 && _losslessDecoder._transforms.first.type == _Vp8LosslessTransformType.colorIndexing && _losslessDecoder._canUseAlphaBuffer();
    return _usesByteDecoder ? _losslessDecoder._allocateAlphaBuffer() : _losslessDecoder._allocatePixelBuffer();
  }

  /// Validates the bounds of rows carrying preprocessed alpha levels.
  bool _validatePreprocessedRows(int row, int rowCount) => row >= 0 && rowCount >= 0 && row + rowCount <= _height;
}
