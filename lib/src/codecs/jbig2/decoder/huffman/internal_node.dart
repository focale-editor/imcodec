// Adapted for Imcodec from jbig2 and Apache PDFBox JBIG2 (Apache-2.0).
// See third_party/jbig2/NOTICE and LICENSE.
part of '../../../jbig2.dart';

/// Implements the JBIG2 internal node procedure.
class _Jbig2InternalNode extends _Jbig2Node {
  /// Stores depth.
  final int _depth;

  /// Stores zero.
  _Jbig2Node? _zero;

  /// Stores one.
  _Jbig2Node? _one;

  /// Creates the internal node state.
  _Jbig2InternalNode({
    this._depth = 0,
  });

  /// Computes append.
  void append(_Jbig2Code c) {
    // ignore unused codes
    if (c.prefixLength == 0) {
      return;
    }

    final int shift = c.prefixLength - 1 - _depth;

    if (shift < 0) {
      throw ArgumentError('Negative shifting is not possible.');
    }

    final int bit = (c.code >> shift) & 1;
    if (shift == 0) {
      if (c.rangeLength == -1) {
        // the child will be a OutOfBand
        if (bit == 1) {
          if (_one != null) {
            throw StateError('already have a OOB for $c');
          }
          _one = _Jbig2OutOfBandNode(c: c);
        } else {
          if (_zero != null) {
            throw StateError('already have a OOB for $c');
          }
          _zero = _Jbig2OutOfBandNode(c: c);
        }
      } else {
        // the child will be a _Jbig2ValueNode
        if (bit == 1) {
          if (_one != null) {
            throw StateError('already have a _Jbig2ValueNode for $c');
          }
          _one = _Jbig2ValueNode(c: c);
        } else {
          if (_zero != null) {
            throw StateError('already have a _Jbig2ValueNode for $c');
          }
          _zero = _Jbig2ValueNode(c: c);
        }
      }
    } else {
      // the child will be an _Jbig2InternalNode
      if (bit == 1) {
        _one ??= _Jbig2InternalNode(depth: _depth + 1);
        (_one as _Jbig2InternalNode).append(c);
      } else {
        _zero ??= _Jbig2InternalNode(depth: _depth + 1);
        (_zero as _Jbig2InternalNode).append(c);
      }
    }
  }

  @override
  int decode(_Jbig2BitReader iis) {
    final int b = iis.readBit();
    final _Jbig2Node? n = b == 0 ? _zero : _one;
    if (n == null) {
      throw StateError('Incomplete Huffman tree or invalid data');
    }
    return n.decode(iis);
  }

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('\n');

    _pad(sb);
    sb.writeln('0: $_zero');
    _pad(sb);
    sb.writeln('1: $_one');

    return sb.toString();
  }

  /// Computes pad.
  void _pad(StringBuffer sb) {
    for (int i = 0; i < _depth; i++) {
      sb.write('   ');
    }
  }
}
