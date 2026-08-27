import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/core/math.dart';
import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';

/// Reads an entropy-coded Lehmer permutation of [size] entries.
/// Frame section tables and VarDCT coefficient orders share this encoding.
List<int> readPermutation(BitReader reader, EntropyStream stream, int size, int skip) {
  int contextFor(int x) {
    final int v = ceilLog1p(x);
    return v < 7 ? v : 7;
  }

  final int end = stream.readSymbol(reader, contextFor(size));
  if (end > size - skip) {
    throw const JpegXlInvalidBitstreamException(message: 'illegal lehmer end value');
  }
  final lehmer = List<int>.filled(size, 0);
  for (var i = skip; i < end + skip; i++) {
    lehmer[i] = stream.readSymbol(reader, contextFor(i > skip ? lehmer[i - 1] : 0));
    if (lehmer[i] >= size - i) {
      throw const JpegXlInvalidBitstreamException(message: 'illegal lehmer value');
    }
  }
  // Decode the Lehmer sequence into a permutation. A naive `removeAt` from
  // a shrinking list is O(size^2); a Fenwick tree of remaining slots makes
  // "select the k-th still-available index" O(log size), which matters for
  // both large legitimate TOCs and adversarial inputs.
  final tree = Int32List(size + 1); // 1-based counts of available slots
  void add(int i, int delta) {
    for (int x = i + 1; x <= size; x += x & -x) {
      tree[x] += delta;
    }
  }

  for (var i = 0; i < size; i++) {
    add(i, 1);
  }
  // Finds the position of the (k+1)-th available slot (0-based k).
  int selectAndRemove(int k) {
    var pos = 0;
    int remaining = k + 1;
    var logSize = 1;
    while (logSize * 2 <= size) {
      logSize *= 2;
    }
    for (var step = logSize; step > 0; step >>= 1) {
      if (pos + step <= size && tree[pos + step] < remaining) {
        pos += step;
        remaining -= tree[pos];
      }
    }
    add(pos, -1); // pos is 0-based index of the found slot
    return pos;
  }

  final permutation = List<int>.filled(size, 0);
  for (var i = 0; i < size; i++) {
    permutation[i] = selectAndRemove(lehmer[i]);
  }
  return permutation;
}

/// The frame's table of contents: section sectionLengths (in file order), the
/// optional permutation, and the section payload bytes.
final class FrameTableOfContents {
  /// Number of payload bytes currently available.
  /// This equals [totalPayloadBytes] for complete input.
  final int availablePayloadBytes;

  /// Number of payload bytes declared by the table.
  final int totalPayloadBytes;

  /// Encoded byte length of each section in file order.
  final List<int> sectionLengths;

  /// Mapping from logical section indices to their file-order indices.
  final List<int>? permutation;

  /// Starting byte offset of each file-order section.
  final List<int> _sectionStarts;

  /// Contiguous payload containing all currently available sections.
  final Uint8List _sectionData;

  /// Readers cached for sections that have already been requested.
  final Map<int, BitReader> _sectionReaders = {};

  /// Reads a frame section table and its payload from [reader].
  factory FrameTableOfContents.read({
    required BitReader reader,
    required int sectionCount,
    bool allowTruncated = false,
  }) {
    List<int>? permutation;
    if (reader.readBool()) {
      final tocStream = EntropyStream.read(reader: reader, distributionCount: 8);
      permutation = readPermutation(reader, tocStream, sectionCount, 0);
      if (!tocStream.validateFinalState()) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid TOC entropy state');
      }
    }
    reader.zeroPadToByte();
    final sectionLengths = List<int>.generate(sectionCount, (_) => reader.readU32(0, 10, 1024, 14, 17408, 22, 4211712, 30));
    reader.zeroPadToByte();

    final starts = List<int>.filled(sectionCount, 0);
    var total = 0;
    for (var i = 0; i < sectionCount; i++) {
      starts[i] = total;
      total += sectionLengths[i];
    }
    // Capture the section payload region, then advance the global reader
    // past it so the next frame can be read.
    final Uint8List data = reader.remainingBytes();
    if (data.length < total) {
      if (!allowTruncated) {
        throw const JpegXlTruncatedException(message: 'frame sections extend past input');
      }
      // Streaming probe: keep whatever payload is present; the reader is
      // left un-advanced (the walk stops at this frame).
      return FrameTableOfContents._(
        sectionLengths: sectionLengths,
        permutation: permutation,
        sectionStarts: starts,
        sectionData: data,
        availablePayloadBytes: data.length,
        totalPayloadBytes: total,
      );
    }
    reader.skipBits(total << 3);
    return FrameTableOfContents._(
      sectionLengths: sectionLengths,
      permutation: permutation,
      sectionStarts: starts,
      sectionData: Uint8List.sublistView(data, 0, total),
      availablePayloadBytes: total,
      totalPayloadBytes: total,
    );
  }

  /// Creates a decoded frame section table.
  FrameTableOfContents._({
    required this.sectionLengths,
    required this.permutation,
    required this._sectionStarts,
    required this._sectionData,
    required this.availablePayloadBytes,
    required this.totalPayloadBytes,
  });

  /// Whether logical section [index] lies fully within the available bytes.
  bool sectionAvailable(int index) {
    final int i = sectionLengths.length <= 1 ? 0 : (permutation?[index] ?? index);
    return _sectionStarts[i] + sectionLengths[i] <= availablePayloadBytes;
  }

  /// Section reader for logical section [index]; repeated calls return the
  /// same reader (single-section frames share one reader across stages).
  BitReader sectionReader(int index) {
    final int i = sectionLengths.length <= 1 ? 0 : (permutation?[index] ?? index);
    return _sectionReaders.putIfAbsent(i, () => BitReader.view(data: _sectionData, start: _sectionStarts[i], end: _sectionStarts[i] + sectionLengths[i]));
  }

  /// The pristine byte range of logical section [index], independent of any
  /// prior [sectionReader] consumption. Public so profiling tools can replay
  /// a single section's decode from scratch (e.g. `tool/bench_entropy.dart`).
  Uint8List sectionBytes(int index) {
    final int i = sectionLengths.length <= 1 ? 0 : (permutation?[index] ?? index);
    return Uint8List.sublistView(_sectionData, _sectionStarts[i], _sectionStarts[i] + sectionLengths[i]);
  }
}
