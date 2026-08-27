import 'dart:typed_data';

/// Grows a typed 32-bit integer buffer without boxing or pointer scanning.
///
/// A `List<int>` stores machine words the garbage collector must scan, and its
/// growth reallocates an object array. The encoder appends tens of millions of
/// residuals, contexts, and properties per image, so those two costs dominate
/// encoding; a [Int32List] holds no pointers, halves the memory, and is
/// measurably faster to fill and to read back.
final class IntBuffer {
  /// Backing storage, larger than [length] whenever spare capacity exists.
  Int32List _values;

  /// Number of appended values.
  int _length = 0;

  /// Creates a buffer that can hold [capacity] values before growing.
  IntBuffer([int capacity = 16]) : _values = Int32List(capacity < 1 ? 1 : capacity);

  /// Number of appended values.
  int get length => _length;

  /// Whether no value has been appended.
  bool get isEmpty => _length == 0;

  /// Returns the value at [index].
  int operator [](int index) => _values[index];

  /// Replaces the value at [index].
  void operator []=(int index, int value) => _values[index] = value;

  /// Appends [value], growing the buffer when it is full.
  void add(int value) {
    if (_length == _values.length) {
      _grow(_length + 1);
    }
    _values[_length++] = value;
  }

  /// Appends every value of [values].
  void addAll(List<int> values) {
    if (_length + values.length > _values.length) {
      _grow(_length + values.length);
    }
    _values.setRange(_length, _length + values.length, values);
    _length += values.length;
  }

  /// Reserves room for [capacity] values in total.
  void reserve(int capacity) {
    if (capacity > _values.length) {
      _grow(capacity);
    }
  }

  /// Returns a view of the appended values.
  /// The view aliases this buffer, so it is only valid until the next append.
  Int32List view() => Int32List.sublistView(_values, 0, _length);

  /// Grows the storage to at least [needed] values, always at least doubling.
  void _grow(int needed) {
    int capacity = _values.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    _values = Int32List(capacity)..setRange(0, _length, _values);
  }
}
