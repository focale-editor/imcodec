import 'dart:typed_data';

import 'package:imcodec/src/codecs/jpeg_xl/entropy/entropy_stream.dart';
import 'package:imcodec/src/codecs/jpeg_xl/exceptions.dart';
import 'package:imcodec/src/codecs/jpeg_xl/io/bit_reader.dart';
import 'package:imcodec/src/codecs/jpeg_xl/util/math_helper.dart';

/// Reads an entropy-coded Lehmer-sequence permutation of [size] entries
/// (used by the TOC and by VarDCT coefficient orders).
List<int> readPermutation(BitReader reader, EntropyStream stream, int size, int skip) {
  int ctx(int x) {
    final int v = ceilLog1p(x);
    return v < 7 ? v : 7;
  }

  final int end = stream.readSymbol(reader, ctx(size));
  if (end > size - skip) {
    throw const JpegXlInvalidBitstreamException(message: 'illegal lehmer end value');
  }
  final lehmer = List<int>.filled(size, 0);
  for (var i = skip; i < end + skip; i++) {
    lehmer[i] = stream.readSymbol(reader, ctx(i > skip ? lehmer[i - 1] : 0));
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

/// The frame's table of contents: section lengths (in file order), the
/// optional permutation, and the section payload bytes.
final class Toc {
  /// Payload bytes actually present (== [totalBytes] unless truncated).
  final int availableBytes;

  /// Total payload bytes the TOC declares.
  final int totalBytes;

  /// Stores the lengths value used while processing JPEG XL data.
  ///
  final List<int> lengths;

  /// Stores the permutation value used while processing JPEG XL data.
  ///
  final List<int>? permutation;

  /// Stores the starts state used internally by the JPEG XL codec.
  ///
  final List<int> _starts;

  /// Stores the data state used internally by the JPEG XL codec.
  ///
  final Uint8List _data;

  /// Reads ers.
  ///
  final Map<int, BitReader> _readers = {};

  /// Processes read information in a JPEG XL codestream.
  ///
  factory Toc.read({
    required BitReader reader,
    required int tocEntries,
    bool allowTruncated = false,
  }) {
    List<int>? permutation;
    if (reader.readBool()) {
      final tocStream = EntropyStream.read(reader: reader, numDists: 8);
      permutation = readPermutation(reader, tocStream, tocEntries, 0);
      if (!tocStream.validateFinalState()) {
        throw const JpegXlInvalidBitstreamException(message: 'invalid TOC entropy state');
      }
    }
    reader.zeroPadToByte();
    final lengths = List<int>.generate(tocEntries, (_) => reader.readU32(0, 10, 1024, 14, 17408, 22, 4211712, 30));
    reader.zeroPadToByte();

    final starts = List<int>.filled(tocEntries, 0);
    var total = 0;
    for (var i = 0; i < tocEntries; i++) {
      starts[i] = total;
      total += lengths[i];
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
      return Toc._(lengths: lengths, permutation: permutation, starts: starts, data: data, availableBytes: data.length, totalBytes: total);
    }
    reader.skipBits(total << 3);
    return Toc._(lengths: lengths, permutation: permutation, starts: starts, data: Uint8List.sublistView(data, 0, total), availableBytes: total, totalBytes: total);
  }

  /// Creates Toc state for JPEG XL processing.
  ///
  Toc._({
    required this.lengths,
    required this.permutation,
    required this._starts,
    required this._data,
    required this.availableBytes,
    required this.totalBytes,
  });

  /// Whether logical section [index] lies fully within the available bytes.
  bool sectionAvailable(int index) {
    final int i = lengths.length <= 1 ? 0 : (permutation?[index] ?? index);
    return _starts[i] + lengths[i] <= availableBytes;
  }

  /// Section reader for logical section [index]; repeated calls return the
  /// same reader (single-section frames share one reader across stages).
  BitReader sectionReader(int index) {
    final int i = lengths.length <= 1 ? 0 : (permutation?[index] ?? index);
    return _readers.putIfAbsent(i, () => BitReader.view(data: _data, start: _starts[i], end: _starts[i] + lengths[i]));
  }

  /// The pristine byte range of logical section [index], independent of any
  /// prior [sectionReader] consumption. Public so profiling tools can replay
  /// a single section's decode from scratch (e.g. `tool/bench_entropy.dart`).
  Uint8List sectionBytes(int index) {
    final int i = lengths.length <= 1 ? 0 : (permutation?[index] ?? index);
    return Uint8List.sublistView(_data, _starts[i], _starts[i] + lengths[i]);
  }
}
