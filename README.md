# Imcodec

Imcodec is a focused Flutter image codec for BMP, JPEG, JPEG XL, PNG, QOI,
TGA, TIFF, and WebP. It keeps a small straight-alpha RGBA image model and
exposes synchronous pure-Dart encoders and decoders, which makes expensive
conversions suitable for `Isolate.run`.

> [!NOTE]
> Animated JPEG XL, PNG, and WebP inputs currently return their first visible
> frame. Decoding preserves straight alpha and hidden RGB values where the source
> format carries them.

## Usage

```dart
import 'dart:isolate';
import 'dart:typed_data';

import 'package:imcodec/imcodec.dart' as img;

Future<Uint8List> exportWebP(
  Uint8List straightRgba,
  int width,
  int height,
) => Isolate.run(() {
  final img.Image image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: straightRgba.buffer,
    bytesOffset: straightRgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeWebP(image);
});
```

The encoder entry points mirror the subset used by almost any image editor:

```dart
final Uint8List png = img.encodePng(image);
final Uint8List jpeg = img.encodeJpg(image, quality: 90);
final Uint8List jpegXl = img.encodeJpegXl(image); // lossless Modular
final Uint8List quickJxl = img.encodeJpegXl(image, effort: img.JpegXlEffort.fast);
final Uint8List webp = img.encodeWebP(image); // lossless VP8L
final Uint8List lossyWebP = img.encodeWebP(image, quality: 82);
final Uint8List bmp = img.encodeBmp(image);
final Uint8List tga = img.encodeTga(image); // RLE by default
final Uint8List qoi = img.encodeQoi(image);
final Uint8List tiff = img.encodeTiff(image); // PackBits by default
```

Decode supported data with format detection or a format-specific function:

```dart
final img.Image decoded = img.decodeImage(encodedBytes);
final img.Image png = img.decodePng(pngBytes);
```

## Spreading encoding across isolates

`encodeWith` is part of `RasterCodec` and `RasterEncoder`, so every codec
accepts a runner and `encodeImageWith` dispatches on format just like
`encodeImage`. Use `runSequentially` to run every task on the current isolate,
`onIsolates` to run one isolate per job, or `onBoundedIsolates` to cap the
number of concurrent isolates:

```dart
final Uint8List jpeg = await img.encodeJpgWith(
  img.onBoundedIsolates,
  image,
  quality: 90,
);
```

JPEG transforms MCU bands independently, JPEG XL spreads its modular groups
and context work, PNG filters row bands independently, and lossless WebP
selects and applies predictor-block bands independently. Lossy WebP currently
encodes inline. JPEG, PNG, and WebP keep small images inline because isolate
startup and byte transfer would cost more than the work saved. Their parallel
output is byte-for-byte identical to synchronous output.

BMP, TGA, and TIFF are dominated by inexpensive byte shuffling or run-length
passes, while QOI carries state from every pixel to the next. Measurements show
that moving their buffers between isolates is slower, so these formats accept
a runner for API consistency but intentionally encode inline.

`decodeImage` defaults to a 100-million-pixel allocation limit. Supply a lower
`maxPixels` value when input comes from an untrusted source.

The format classes can also be used through `dart:convert`:

```dart
final img.PngCodec codec = img.PngCodec(level: 7);
final Uint8List encoded = codec.encoder.convert(image);
final img.Image decoded = codec.decoder.convert(encoded);
```

Each `RasterCodec` composes a `RasterEncoder` and a `RasterDecoder`. The
shared `defaultMaxPixels` constant (100 million) is used unless a lower
`maxPixels` limit is supplied to a codec or decoding helper.

## Format behavior

A documentation on the behavior and implementation of formats in available in
[docs/formats.md](docs/formats.md).

The JPEG and WebP encoder implementations contain code derived from the MIT
licensed Dart `image` package.

The JPEG XL implementation is adapted from
[`koni_jxl`](https://github.com/zenbaku/koni_jxl), released by Jonathan Urzúa
under the MIT License. Its decoding logic includes work derived from the MIT
licensed [`JXLatte`](https://github.com/Traneptora/jxlatte) project.
