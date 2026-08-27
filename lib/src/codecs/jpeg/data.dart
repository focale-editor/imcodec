part of '../jpeg.dart';

/// Parses JPEG segments and owns the decoded frequency-domain components.
final class _JpegData {
  /// Maximum number of quantization tables addressable by JPEG components.
  static const int _quantizationTableCount = 4;

  /// Maximum number of components permitted in one entropy scan.
  static const int _maximumScanComponents = 4;

  /// Maximum number of Huffman tables addressable per table class.
  static const int _huffmanTableCount = 4;

  /// Maximum number of decoded output pixels.
  final int maxPixels;

  /// Quantization tables indexed by their stream identifier.
  final List<Int16List?> quantizationTables = List<Int16List?>.filled(_quantizationTableCount, null);

  /// Alternating-current Huffman tables indexed by their stream identifier.
  final List<_JpegHuffmanTable?> huffmanTablesAc = List<_JpegHuffmanTable?>.filled(_huffmanTableCount, null);

  /// Direct-current Huffman tables indexed by their stream identifier.
  final List<_JpegHuffmanTable?> huffmanTablesDc = List<_JpegHuffmanTable?>.filled(_huffmanTableCount, null);

  /// Spatial sample planes produced after inverse transformation.
  final List<_JpegComponentData> components = [];

  /// Reader over the complete encoded image.
  late _JpegInput input;

  /// Adobe application marker needed to distinguish CMYK from YCCK.
  _JpegAdobeMarker? adobeMarker;

  /// Single image frame described by the stream.
  _JpegFrame? frame;

  /// Number of minimum coded units between restart markers.
  int? resetInterval;

  /// Display orientation read from EXIF metadata.
  int orientation = 1;

  /// Whether at least one start-of-scan segment was decoded.
  bool _hasScan = false;

  /// Creates an empty parser with a bounded output allocation.
  _JpegData({
    required this.maxPixels,
  });

  /// Image width in pixels.
  int get width => frame?.samplesPerLine ?? 0;

  /// Image height in pixels.
  int get height => frame?.scanLines ?? 0;

  /// Parses all segments and reconstructs spatial component samples.
  void read(Uint8List bytes) {
    input = _JpegInput(bytes: bytes);
    _readSegments();
    final _JpegFrame? decodedFrame = frame;
    if (decodedFrame == null || !_hasScan) {
      throw const ImageCodecException('JPEG is missing frame or scan data');
    }
    for (final int componentIdentifier in decodedFrame.componentsOrder) {
      final _JpegComponent component = decodedFrame.components[componentIdentifier]!;
      components.add(
        _JpegComponentData(
          horizontalSamples: component.horizontalSamples,
          maximumHorizontalSamples: decodedFrame.maximumHorizontalSamples,
          verticalSamples: component.verticalSamples,
          maximumVerticalSamples: decodedFrame.maximumVerticalSamples,
          lines: _buildComponentData(component),
          width: decodedFrame.samplesPerLine,
          height: decodedFrame.scanLines,
        ),
      );
    }
  }

  /// Dispatches marker segments until the end-of-image marker.
  void _readSegments() {
    int marker = _nextMarker();
    if (marker != JpegMarker.startOfImage) {
      throw const ImageCodecException('JPEG start-of-image marker is missing');
    }
    marker = _nextMarker();
    while (marker != JpegMarker.endOfImage) {
      if (marker == 0 || input.isEOS) {
        throw const ImageCodecException('JPEG end-of-image marker is missing');
      }
      final _JpegInput block = _readBlock();
      switch (marker) {
        case >= JpegMarker.application0 && <= JpegMarker.application15:
          _readApplicationMarker(marker, block);
        case JpegMarker.comment:
          break;
        case JpegMarker.defineQuantizationTable:
          _readQuantizationTables(block);
        case JpegMarker.startOfFrameBaseline || JpegMarker.startOfFrameExtended || JpegMarker.startOfFrameProgressive:
          _readFrame(marker, block);
        case JpegMarker.defineHuffmanTable:
          _readHuffmanTables(block);
        case JpegMarker.defineRestartInterval:
          _readRestartInterval(block);
        case JpegMarker.startOfScan:
          _readScan(block);
        case JpegMarker.startOfFrameLossless ||
            JpegMarker.startOfFrameDifferentialSequential ||
            JpegMarker.startOfFrameDifferentialProgressive ||
            JpegMarker.startOfFrameDifferentialLossless ||
            JpegMarker.startOfFrameArithmeticExtended ||
            JpegMarker.startOfFrameArithmeticProgressive ||
            JpegMarker.startOfFrameArithmeticLossless ||
            JpegMarker.startOfFrameArithmeticDifferentialSequential ||
            JpegMarker.startOfFrameArithmeticDifferentialProgressive ||
            JpegMarker.startOfFrameArithmeticDifferentialLossless:
          throw ImageCodecException('Unsupported JPEG frame marker: 0x${marker.toRadixString(16)}');
        default:
          throw ImageCodecException('Unsupported JPEG marker: 0x${marker.toRadixString(16)}');
      }
      marker = _nextMarker();
    }
  }

  /// Reads application metadata that affects pixel interpretation.
  void _readApplicationMarker(int marker, _JpegInput block) {
    if (marker == JpegMarker.application1) {
      orientation = _readExifOrientation(block);
    } else if (marker == JpegMarker.application14) {
      _readAdobeMarker(block);
    }
  }

  /// Reads the orientation tag from a bounded EXIF TIFF directory.
  int _readExifOrientation(_JpegInput block) {
    final Uint8List data = block.toUint8List();
    if (data.length < 14 || data[0] != 0x45 || data[1] != 0x78 || data[2] != 0x69 || data[3] != 0x66 || data[4] != 0 || data[5] != 0) {
      return 1;
    }
    final ByteData values = ByteData.sublistView(data);
    final Endian endian;
    if (data[6] == 0x49 && data[7] == 0x49) {
      endian = Endian.little;
    } else if (data[6] == 0x4d && data[7] == 0x4d) {
      endian = Endian.big;
    } else {
      return 1;
    }
    if (values.getUint16(8, endian) != 42) {
      return 1;
    }
    final int directoryOffset = 6 + values.getUint32(10, endian);
    if (directoryOffset < 6 || directoryOffset > data.length - 2) {
      return 1;
    }
    final int entryCount = values.getUint16(directoryOffset, endian);
    int entryOffset = directoryOffset + 2;
    for (int entry = 0; entry < entryCount; entry++, entryOffset += 12) {
      if (entryOffset > data.length - 12) {
        return 1;
      }
      if (values.getUint16(entryOffset, endian) == 274 && values.getUint16(entryOffset + 2, endian) == 3 && values.getUint32(entryOffset + 4, endian) == 1) {
        final int candidate = values.getUint16(entryOffset + 8, endian);
        return candidate >= 1 && candidate <= 8 ? candidate : 1;
      }
    }
    return 1;
  }

  /// Reads a length-prefixed marker payload.
  _JpegInput _readBlock() {
    final int length = input.readUint16();
    if (length < 2) {
      throw const ImageCodecException('JPEG segment length must include its two-byte length field');
    }
    return input.readBytes(length - 2);
  }

  /// Finds the next non-stuffed marker byte.
  int _nextMarker() {
    while (!input.isEOS) {
      int value = input.readByte();
      if (value != 0xff) {
        continue;
      }
      do {
        if (input.isEOS) {
          return 0;
        }
        value = input.readByte();
      } while (value == 0xff);
      if (value != 0) {
        return value;
      }
    }
    return 0;
  }

  /// Reads the Adobe marker used by four-component JPEG images.
  void _readAdobeMarker(_JpegInput block) {
    if (block.length < 13 || block[0] != 0x41 || block[1] != 0x64 || block[2] != 0x6f || block[3] != 0x62 || block[4] != 0x65 || block[5] != 0) {
      return;
    }
    adobeMarker = _JpegAdobeMarker(
      version: (block[6] << 8) | block[7],
      flags0: (block[8] << 8) | block[9],
      flags1: (block[10] << 8) | block[11],
      transformCode: block[12],
    );
  }

  /// Reads one or more quantization tables.
  void _readQuantizationTables(_JpegInput block) {
    while (!block.isEOS) {
      final int specification = block.readByte();
      final int precision = specification >>> 4;
      final int identifier = specification & 0x0f;
      if (precision > 1 || identifier >= _quantizationTableCount) {
        throw const ImageCodecException('Invalid JPEG quantization-table specification');
      }
      final Int16List table = Int16List(64);
      for (int index = 0; index < 64; index++) {
        table[jpegZigZagToNaturalOrder[index]] = precision == 0 ? block.readByte() : block.readUint16();
      }
      quantizationTables[identifier] = table;
    }
  }

  /// Reads frame dimensions, sampling factors, and component identifiers.
  void _readFrame(int marker, _JpegInput block) {
    if (frame != null) {
      throw const ImageCodecException('JPEG contains more than one frame header');
    }
    final int precision = block.readByte();
    final int height = block.readUint16();
    final int width = block.readUint16();
    final int componentCount = block.readByte();
    if (precision != 8) {
      throw ImageCodecException('Unsupported JPEG sample precision: $precision');
    }
    _checkDimensions(width, height);
    if (componentCount != 1 && componentCount != 3 && componentCount != 4) {
      throw ImageCodecException('Unsupported JPEG component count: $componentCount');
    }
    if (block.length != componentCount * 3) {
      throw const ImageCodecException('Invalid JPEG frame-header length');
    }
    final _JpegFrame decodedFrame = _JpegFrame(
      progressive: marker == JpegMarker.startOfFrameProgressive,
      precision: precision,
      scanLines: height,
      samplesPerLine: width,
    );
    for (int index = 0; index < componentCount; index++) {
      final int identifier = block.readByte();
      final int sampling = block.readByte();
      final int horizontalSamples = sampling >>> 4;
      final int verticalSamples = sampling & 0x0f;
      final int quantizationIndex = block.readByte();
      if (decodedFrame.components.containsKey(identifier) ||
          horizontalSamples < 1 ||
          horizontalSamples > 4 ||
          verticalSamples < 1 ||
          verticalSamples > 4 ||
          quantizationIndex >= _quantizationTableCount) {
        throw const ImageCodecException('Invalid JPEG frame component');
      }
      decodedFrame.componentsOrder.add(identifier);
      decodedFrame.components[identifier] = _JpegComponent(
        horizontalSamples: horizontalSamples,
        verticalSamples: verticalSamples,
        quantizationTables: quantizationTables,
        quantizationIndex: quantizationIndex,
      );
    }
    decodedFrame.prepare();
    frame = decodedFrame;
  }

  /// Reads one or more canonical Huffman tables.
  void _readHuffmanTables(_JpegInput block) {
    while (!block.isEOS) {
      final int specification = block.readByte();
      final bool alternatingCurrent = (specification & 0x10) != 0;
      final int tableClass = specification >>> 4;
      final int identifier = specification & 0x0f;
      if (tableClass > 1 || identifier >= _huffmanTableCount) {
        throw const ImageCodecException('Invalid JPEG Huffman-table specification');
      }
      final Uint8List codeLengths = Uint8List(16);
      int valueCount = 0;
      for (int index = 0; index < codeLengths.length; index++) {
        codeLengths[index] = block.readByte();
        valueCount += codeLengths[index];
      }
      if (valueCount > 256 || valueCount > block.length) {
        throw const ImageCodecException('Invalid JPEG Huffman-table length');
      }
      final Uint8List values = Uint8List.fromList(block.readBytes(valueCount).toUint8List());
      final _JpegHuffmanTable table = _JpegHuffmanTable(codeLengths: codeLengths, symbols: values);
      final List<_JpegHuffmanTable?> tables = alternatingCurrent ? huffmanTablesAc : huffmanTablesDc;
      tables[identifier] = table;
    }
  }

  /// Reads the restart interval used by subsequent scans.
  void _readRestartInterval(_JpegInput block) {
    if (block.length != 2) {
      throw const ImageCodecException('JPEG restart interval must contain two bytes');
    }
    resetInterval = block.readUint16();
  }

  /// Configures components and decodes one entropy-coded scan.
  void _readScan(_JpegInput block) {
    final _JpegFrame? decodedFrame = frame;
    if (decodedFrame == null) {
      throw const ImageCodecException('JPEG scan appears before its frame header');
    }
    final int componentCount = block.readByte();
    if (componentCount < 1 || componentCount > _maximumScanComponents || block.length != componentCount * 2 + 3) {
      throw const ImageCodecException('Invalid JPEG scan header');
    }
    final List<int> directCurrentIndices = [];
    final List<int> alternatingCurrentIndices = [];
    final List<_JpegComponent> scanComponents = List<_JpegComponent>.generate(
      componentCount,
      (index) {
        final int identifier = block.readByte();
        final int tableSelectors = block.readByte();
        final _JpegComponent? component = decodedFrame.components[identifier];
        if (component == null) {
          throw const ImageCodecException('JPEG scan references an unknown component');
        }
        final int directCurrentIndex = tableSelectors >>> 4;
        final int alternatingCurrentIndex = tableSelectors & 0x0f;
        directCurrentIndices.add(directCurrentIndex);
        alternatingCurrentIndices.add(alternatingCurrentIndex);
        return component;
      },
      growable: false,
    );
    final int spectralStart = block.readByte();
    final int spectralEnd = block.readByte();
    final int approximation = block.readByte();
    final int successivePrevious = approximation >>> 4;
    final int successive = approximation & 0x0f;
    if (spectralStart > spectralEnd || spectralEnd > 63 || (!decodedFrame.progressive && (spectralStart != 0 || spectralEnd != 63 || approximation != 0))) {
      throw const ImageCodecException('Invalid JPEG spectral selection');
    }
    for (int index = 0; index < scanComponents.length; index++) {
      final _JpegComponent component = scanComponents[index];
      if (spectralStart == 0) {
        final int tableIndex = directCurrentIndices[index];
        if (tableIndex >= _huffmanTableCount || huffmanTablesDc[tableIndex] == null) {
          throw const ImageCodecException('JPEG scan references a missing direct-current Huffman table');
        }
        component.huffmanTableDc = huffmanTablesDc[tableIndex]!;
      }
      if (spectralEnd > 0) {
        final int tableIndex = alternatingCurrentIndices[index];
        if (tableIndex >= _huffmanTableCount || huffmanTablesAc[tableIndex] == null) {
          throw const ImageCodecException('JPEG scan references a missing alternating-current Huffman table');
        }
        component.huffmanTableAc = huffmanTablesAc[tableIndex]!;
      }
    }
    _JpegScanDecoder(
      input: input,
      frame: decodedFrame,
      components: scanComponents,
      resetInterval: resetInterval,
      spectralStart: spectralStart,
      spectralEnd: spectralEnd,
      successivePrevious: successivePrevious,
      successive: successive,
    ).decode();
    _hasScan = true;
  }

  /// Applies inverse transformation to every block of one component.
  List<Uint8List> _buildComponentData(_JpegComponent component) {
    final Int16List? quantizationTable = component.quantizationTable;
    if (quantizationTable == null) {
      throw const ImageCodecException('JPEG component references a missing quantization table');
    }
    final int samplesPerLine = component.blocksPerLine << 3;
    final Int32List intermediate = Int32List(64);
    final Uint8List transformed = Uint8List(64);
    final List<Uint8List> lines = List<Uint8List>.generate(component.blocksPerColumn * 8, (index) => Uint8List(samplesPerLine), growable: false);
    for (int blockRow = 0; blockRow < component.blocksPerColumn; blockRow++) {
      final int scanLine = blockRow << 3;
      for (int blockColumn = 0; blockColumn < component.blocksPerLine; blockColumn++) {
        _inverseTransformBlock(quantizationTable, component.blocks[blockRow][blockColumn], transformed, intermediate);
        int source = 0;
        final int destination = blockColumn << 3;
        for (int row = 0; row < 8; row++) {
          lines[scanLine + row].setRange(destination, destination + 8, transformed, source);
          source += 8;
        }
      }
    }
    return lines;
  }

  /// Rejects dimensions before frequency or pixel buffers are allocated.
  void _checkDimensions(int width, int height) {
    if (width < 1 || height < 1) {
      throw const ImageCodecException('JPEG dimensions must be positive and non-zero');
    }
    final int pixelCount = width * height;
    if (pixelCount > maxPixels) {
      throw ImageCodecException('Decoded image contains $pixelCount pixels, exceeding the $maxPixels pixel limit');
    }
  }
}
