import 'dart:typed_data';

import 'package:imcodec/src/image.dart';

/// Configures palette reduction for indexed image formats.
final class IndexedColorOptions {
  /// Maximum number of palette entries, including transparency.
  final int colorCount;

  /// Percentage of Floyd–Steinberg quantization error to diffuse.
  final int ditherAmount;

  /// Whether pixels below [alphaThreshold] use one transparent palette entry.
  final bool transparency;

  /// Packed ARGB matte used for partial or disabled transparency.
  final int matteColorValue;

  /// Alpha values below this threshold become fully transparent.
  final int alphaThreshold;

  /// Creates indexed colour-reduction settings.
  const IndexedColorOptions({
    this.colorCount = 256,
    this.ditherAmount = 100,
    this.transparency = true,
    this.matteColorValue = 0xffffffff,
    this.alphaThreshold = 128,
  }) : assert(
         colorCount >= 2 && colorCount <= 256,
         'Indexed colour count must be between 2 and 256.',
       ),
       assert(
         ditherAmount >= 0 && ditherAmount <= 100,
         'Indexed dither amount must be between 0 and 100.',
       ),
       assert(
         matteColorValue >= 0 && matteColorValue <= 0xffffffff,
         'Indexed matte colour must be a packed ARGB value.',
       ),
       assert(
         alphaThreshold >= 0 && alphaThreshold <= 255,
         'Indexed alpha threshold must be between 0 and 255.',
       );

  /// Checks settings when assertions are disabled.
  void validate() {
    if (colorCount < 2 || colorCount > 256) {
      throw RangeError.range(colorCount, 2, 256, 'colorCount');
    }
    if (ditherAmount < 0 || ditherAmount > 100) {
      throw RangeError.range(ditherAmount, 0, 100, 'ditherAmount');
    }
    if (matteColorValue < 0 || matteColorValue > 0xffffffff) {
      throw RangeError.range(
        matteColorValue,
        0,
        0xffffffff,
        'matteColorValue',
      );
    }
    if (alphaThreshold < 0 || alphaThreshold > 255) {
      throw RangeError.range(alphaThreshold, 0, 255, 'alphaThreshold');
    }
  }
}

/// Stores a palette and one byte-sized index for every source pixel.
final class IndexedColorImage {
  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Palette entries in straight RGBA order.
  final Uint8List palette;

  /// Palette index for every pixel in row-major order.
  final Uint8List indices;

  /// Transparent palette index, or `null` for an opaque result.
  final int? transparentIndex;

  /// Creates a quantized indexed image.
  const IndexedColorImage({
    required this.width,
    required this.height,
    required this.palette,
    required this.indices,
    required this.transparentIndex,
  });

  /// Number of entries in [palette].
  int get paletteLength => palette.length ~/ 4;
}

/// Reduces [image] to a deterministic median-cut palette.
IndexedColorImage quantizeIndexedColor(
  Image image, {
  IndexedColorOptions options = const IndexedColorOptions(),
}) {
  options.validate();
  final _PreparedHistogram prepared = _PreparedHistogram.fromImage(
    image,
    options,
  );
  final int transparentOffset = prepared.hasTransparency ? 1 : 0;
  final int opaqueColorLimit = options.colorCount - transparentOffset;
  final List<_HistogramColor> colors = prepared.colors;
  final List<_ColorBox> boxes = colors.isEmpty ? const [] : _partitionColors(colors, opaqueColorLimit);
  final Uint8List palette = Uint8List(
    (boxes.length + transparentOffset) * 4,
  );
  if (prepared.hasTransparency) {
    palette.setRange(0, 4, const [0, 0, 0, 0]);
  }
  for (int index = 0; index < boxes.length; index++) {
    final _PaletteColor color = boxes[index].average;
    final int offset = (index + transparentOffset) * 4;
    palette[offset] = color.red;
    palette[offset + 1] = color.green;
    palette[offset + 2] = color.blue;
    palette[offset + 3] = 255;
  }

  if (boxes.isEmpty) {
    return IndexedColorImage(
      width: image.width,
      height: image.height,
      palette: palette,
      indices: Uint8List(image.width * image.height),
      transparentIndex: prepared.hasTransparency ? 0 : null,
    );
  }

  final _PaletteLookup lookup = _PaletteLookup(
    palette: palette,
    firstOpaqueIndex: transparentOffset,
  );
  final Uint8List indices = options.ditherAmount == 0
      ? _mapWithoutDither(
          image,
          prepared,
          lookup,
        )
      : _mapWithDither(
          image,
          prepared,
          options,
          lookup,
        );
  return IndexedColorImage(
    width: image.width,
    height: image.height,
    palette: palette,
    indices: indices,
    transparentIndex: prepared.hasTransparency ? 0 : null,
  );
}

/// Splits occupied histogram cells until [limit] representative boxes exist.
List<_ColorBox> _partitionColors(
  List<_HistogramColor> colors,
  int limit,
) {
  final List<_ColorBox> boxes = [_ColorBox(colors)];
  while (boxes.length < limit) {
    int candidateIndex = -1;
    int candidateScore = -1;
    for (int index = 0; index < boxes.length; index++) {
      final _ColorBox box = boxes[index];
      if (box.colors.length < 2) {
        continue;
      }
      final int score = box.splitScore;
      if (score > candidateScore) {
        candidateIndex = index;
        candidateScore = score;
      }
    }
    if (candidateIndex < 0) {
      break;
    }
    final (_ColorBox first, _ColorBox second) = boxes[candidateIndex].split();
    boxes[candidateIndex] = first;
    boxes.add(second);
  }
  return boxes;
}

/// Maps prepared pixels through [lookup] without propagating colour error.
Uint8List _mapWithoutDither(
  Image image,
  _PreparedHistogram prepared,
  _PaletteLookup lookup,
) {
  final Uint8List indices = Uint8List(image.width * image.height);
  for (int pixel = 0; pixel < indices.length; pixel++) {
    final int source = pixel * 4;
    if (prepared.isTransparent(image.bytes[source + 3])) {
      indices[pixel] = 0;
      continue;
    }
    final (int red, int green, int blue) = prepared.compositeAt(
      image.bytes,
      source,
    );
    indices[pixel] = lookup.indexFor(red, green, blue);
  }
  return indices;
}

/// Maps pixels with bounded Floyd–Steinberg error diffusion.
Uint8List _mapWithDither(
  Image image,
  _PreparedHistogram prepared,
  IndexedColorOptions options,
  _PaletteLookup lookup,
) {
  final Uint8List indices = Uint8List(image.width * image.height);
  final int errorRowLength = (image.width + 2) * 3;
  Int32List currentErrors = Int32List(errorRowLength);
  Int32List nextErrors = Int32List(errorRowLength);
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final int pixel = y * image.width + x;
      final int source = pixel * 4;
      final int errorOffset = (x + 1) * 3;
      if (prepared.isTransparent(image.bytes[source + 3])) {
        indices[pixel] = 0;
        continue;
      }
      final (int baseRed, int baseGreen, int baseBlue) = prepared.compositeAt(
        image.bytes,
        source,
      );
      final int red = (baseRed + _roundedSixteenth(currentErrors[errorOffset])).clamp(0, 255);
      final int green = (baseGreen + _roundedSixteenth(currentErrors[errorOffset + 1])).clamp(0, 255);
      final int blue = (baseBlue + _roundedSixteenth(currentErrors[errorOffset + 2])).clamp(0, 255);
      final int paletteIndex = lookup.indexFor(red, green, blue);
      indices[pixel] = paletteIndex;
      final int paletteOffset = paletteIndex * 4;
      _diffuseError(
        currentErrors,
        nextErrors,
        errorOffset,
        red - lookup.palette[paletteOffset],
        green - lookup.palette[paletteOffset + 1],
        blue - lookup.palette[paletteOffset + 2],
        options.ditherAmount,
      );
    }
    final Int32List completedErrors = currentErrors;
    currentErrors = nextErrors;
    nextErrors = completedErrors..fillRange(0, errorRowLength, 0);
  }
  return indices;
}

/// Rounds one fixed-point error whose denominator is sixteen.
int _roundedSixteenth(int value) => value >= 0 ? (value + 8) ~/ 16 : -((-value + 8) ~/ 16);

/// Distributes one RGB error to the four future Floyd–Steinberg neighbours.
void _diffuseError(
  Int32List current,
  Int32List next,
  int offset,
  int redError,
  int greenError,
  int blueError,
  int amount,
) {
  final int red = redError * amount ~/ 100;
  final int green = greenError * amount ~/ 100;
  final int blue = blueError * amount ~/ 100;
  for (int channel = 0; channel < 3; channel++) {
    final int error = switch (channel) {
      0 => red,
      1 => green,
      _ => blue,
    };
    current[offset + 3 + channel] += error * 7;
    next[offset - 3 + channel] += error * 3;
    next[offset + channel] += error * 5;
    next[offset + 3 + channel] += error;
  }
}

/// Stores occupied five-bit RGB histogram cells.
final class _PreparedHistogram {
  /// Number of bits retained per colour channel.
  static const int _channelBits = 5;

  /// Number of low bits discarded per colour channel.
  static const int _channelShift = 8 - _channelBits;

  /// Mask for one quantized colour channel.
  static const int _channelMask = (1 << _channelBits) - 1;

  /// Reduction settings used to prepare pixels.
  final IndexedColorOptions options;

  /// Packed matte red channel.
  final int matteRed;

  /// Packed matte green channel.
  final int matteGreen;

  /// Packed matte blue channel.
  final int matteBlue;

  /// Occupied histogram cells.
  final List<_HistogramColor> colors;

  /// Whether at least one source pixel becomes transparent.
  final bool hasTransparency;

  /// Creates prepared histogram state.
  const _PreparedHistogram({
    required this.options,
    required this.matteRed,
    required this.matteGreen,
    required this.matteBlue,
    required this.colors,
    required this.hasTransparency,
  });

  /// Builds a histogram after applying indexed-alpha semantics.
  factory _PreparedHistogram.fromImage(
    Image image,
    IndexedColorOptions options,
  ) {
    final int matteRed = (options.matteColorValue >>> 16) & 0xff;
    final int matteGreen = (options.matteColorValue >>> 8) & 0xff;
    final int matteBlue = options.matteColorValue & 0xff;
    final Int32List counts = Int32List(1 << (_channelBits * 3));
    final Int64List redSums = Int64List(counts.length);
    final Int64List greenSums = Int64List(counts.length);
    final Int64List blueSums = Int64List(counts.length);
    bool hasTransparency = false;
    final Uint8List bytes = image.bytes;
    for (int offset = 0; offset < bytes.length; offset += 4) {
      final int alpha = bytes[offset + 3];
      if (options.transparency && alpha < options.alphaThreshold) {
        hasTransparency = true;
        continue;
      }
      final int red = _composite(bytes[offset], alpha, matteRed);
      final int green = _composite(bytes[offset + 1], alpha, matteGreen);
      final int blue = _composite(bytes[offset + 2], alpha, matteBlue);
      final int histogramIndex = _histogramIndex(red, green, blue);
      counts[histogramIndex]++;
      redSums[histogramIndex] += red;
      greenSums[histogramIndex] += green;
      blueSums[histogramIndex] += blue;
    }
    final List<_HistogramColor> colors = [];
    for (int index = 0; index < counts.length; index++) {
      final int count = counts[index];
      if (count == 0) {
        continue;
      }
      colors.add(
        _HistogramColor(
          count: count,
          red: (redSums[index] / count).round(),
          green: (greenSums[index] / count).round(),
          blue: (blueSums[index] / count).round(),
        ),
      );
    }
    return _PreparedHistogram(
      options: options,
      matteRed: matteRed,
      matteGreen: matteGreen,
      matteBlue: matteBlue,
      colors: colors,
      hasTransparency: hasTransparency,
    );
  }

  /// Whether [alpha] maps to the transparent palette entry.
  bool isTransparent(int alpha) => options.transparency && alpha < options.alphaThreshold;

  /// Composites one source pixel against the configured matte.
  (int red, int green, int blue) compositeAt(
    Uint8List bytes,
    int offset,
  ) {
    final int alpha = bytes[offset + 3];
    return (
      _composite(bytes[offset], alpha, matteRed),
      _composite(bytes[offset + 1], alpha, matteGreen),
      _composite(bytes[offset + 2], alpha, matteBlue),
    );
  }

  /// Resolves one RGB colour to its five-bit histogram cell.
  static int _histogramIndex(int red, int green, int blue) =>
      ((red >>> _channelShift) & _channelMask) << (_channelBits * 2) | ((green >>> _channelShift) & _channelMask) << _channelBits | ((blue >>> _channelShift) & _channelMask);

  /// Composites one channel against [matte] with integer rounding.
  static int _composite(int channel, int alpha, int matte) => alpha == 255 ? channel : (channel * alpha + matte * (255 - alpha) + 127) ~/ 255;
}

/// Stores one occupied histogram cell.
final class _HistogramColor {
  /// Number of source pixels represented by this cell.
  final int count;

  /// Average red channel.
  final int red;

  /// Average green channel.
  final int green;

  /// Average blue channel.
  final int blue;

  /// Creates one occupied colour cell.
  const _HistogramColor({
    required this.count,
    required this.red,
    required this.green,
    required this.blue,
  });
}

/// Represents a median-cut partition of occupied histogram cells.
final class _ColorBox {
  /// Histogram cells in this partition.
  final List<_HistogramColor> colors;

  /// Total source population represented by [colors].
  late final int population = colors.fold(
    0,
    (total, color) => total + color.count,
  );

  /// Minimum and maximum red values.
  late final (int minimum, int maximum) redRange = _rangeOf(
    (color) => color.red,
  );

  /// Minimum and maximum green values.
  late final (int minimum, int maximum) greenRange = _rangeOf(
    (color) => color.green,
  );

  /// Minimum and maximum blue values.
  late final (int minimum, int maximum) blueRange = _rangeOf(
    (color) => color.blue,
  );

  /// Creates one immutable partition.
  _ColorBox(List<_HistogramColor> colors) : colors = List.unmodifiable(colors);

  /// Priority used to choose the next partition to split.
  int get splitScore {
    final int redSpan = redRange.$2 - redRange.$1;
    final int greenSpan = greenRange.$2 - greenRange.$1;
    final int blueSpan = blueRange.$2 - blueRange.$1;
    return population * (redSpan * 3 + greenSpan * 4 + blueSpan * 2);
  }

  /// Population-weighted representative colour.
  _PaletteColor get average {
    int red = 0;
    int green = 0;
    int blue = 0;
    for (final _HistogramColor color in colors) {
      red += color.red * color.count;
      green += color.green * color.count;
      blue += color.blue * color.count;
    }
    return _PaletteColor(
      red: (red / population).round(),
      green: (green / population).round(),
      blue: (blue / population).round(),
    );
  }

  /// Divides the partition around its population median.
  (_ColorBox first, _ColorBox second) split() {
    final int redSpan = (redRange.$2 - redRange.$1) * 3;
    final int greenSpan = (greenRange.$2 - greenRange.$1) * 4;
    final int blueSpan = (blueRange.$2 - blueRange.$1) * 2;
    final int Function(_HistogramColor color) channel = greenSpan >= redSpan && greenSpan >= blueSpan
        ? (color) => color.green
        : redSpan >= blueSpan
        ? (color) => color.red
        : (color) => color.blue;
    final List<_HistogramColor> sorted = [...colors]..sort((first, second) => channel(first).compareTo(channel(second)));
    final int medianPopulation = population ~/ 2;
    int cumulative = 0;
    int splitIndex = 1;
    for (int index = 0; index < sorted.length - 1; index++) {
      cumulative += sorted[index].count;
      if (cumulative >= medianPopulation) {
        splitIndex = index + 1;
        break;
      }
    }
    return (
      _ColorBox(sorted.sublist(0, splitIndex)),
      _ColorBox(sorted.sublist(splitIndex)),
    );
  }

  /// Finds the inclusive minimum and maximum produced by [channel].
  (int minimum, int maximum) _rangeOf(
    int Function(_HistogramColor color) channel,
  ) {
    int minimum = 255;
    int maximum = 0;
    for (final _HistogramColor color in colors) {
      final int value = channel(color);
      if (value < minimum) {
        minimum = value;
      }
      if (value > maximum) {
        maximum = value;
      }
    }
    return (minimum, maximum);
  }
}

/// Stores one opaque palette colour.
final class _PaletteColor {
  /// Red channel.
  final int red;

  /// Green channel.
  final int green;

  /// Blue channel.
  final int blue;

  /// Creates one palette colour.
  const _PaletteColor({
    required this.red,
    required this.green,
    required this.blue,
  });
}

/// Caches nearest-palette searches by five-bit RGB cell.
final class _PaletteLookup {
  /// Palette entries in RGBA order.
  final Uint8List palette;

  /// First opaque palette entry.
  final int firstOpaqueIndex;

  /// Cached palette indices, or `-1` before a cell is visited.
  final Int16List _indices = Int16List(1 << 15)..fillRange(0, 1 << 15, -1);

  /// Creates one lookup for [palette].
  _PaletteLookup({
    required this.palette,
    required this.firstOpaqueIndex,
  });

  /// Returns the nearest palette entry for one RGB colour.
  int indexFor(int red, int green, int blue) {
    final int cacheIndex = (red >>> 3) << 10 | (green >>> 3) << 5 | (blue >>> 3);
    final int cached = _indices[cacheIndex];
    if (cached >= 0) {
      return cached;
    }
    int nearest = firstOpaqueIndex;
    int nearestDistance = 0x7fffffff;
    for (int index = firstOpaqueIndex; index < palette.length ~/ 4; index++) {
      final int offset = index * 4;
      final int redDifference = red - palette[offset];
      final int greenDifference = green - palette[offset + 1];
      final int blueDifference = blue - palette[offset + 2];
      final int distance = redDifference * redDifference * 3 + greenDifference * greenDifference * 4 + blueDifference * blueDifference * 2;
      if (distance < nearestDistance) {
        nearest = index;
        nearestDistance = distance;
      }
    }
    _indices[cacheIndex] = nearest;
    return nearest;
  }
}
