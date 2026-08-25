# Imcodec

Imcodec is a focused Flutter image codec for BMP, JPEG, JPEG XL, PNG, QOI,
TGA, TIFF, and WebP. It keeps a small straight-alpha RGBA image model and exposes
synchronous Dart encoders, which makes expensive encoding suitable for
`Isolate.run`.

Decoding is asynchronous at the public boundary. BMP, JPEG XL, QOI, TGA, and
TIFF use pure-Dart decoders; JPEG, PNG, and WebP use Flutter's platform codecs.
Animated JPEG XL, PNG, and WebP inputs currently return their first frame. Flutter's premultiplied
render pipeline may round RGB values on translucent pixels and discards hidden
RGB values where alpha is zero.

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
final Uint8List webp = img.encodeWebP(image); // lossless VP8L
final Uint8List bmp = img.encodeBmp(image);
final Uint8List tga = img.encodeTga(image); // RLE by default
final Uint8List qoi = img.encodeQoi(image);
final Uint8List tiff = img.encodeTiff(image); // PackBits by default
```

Decode supported data with format detection or a format-specific function:

```dart
final img.Image decoded = await img.decodeImage(encodedBytes);
final img.Image png = await img.decodePng(pngBytes);
```

`decodeImage` defaults to a 100-million-pixel allocation limit. Supply a lower
`maxPixels` value when input comes from an untrusted source.

## Format behavior

- BMP is encoded as a V4 32-bit bitmap with explicit RGBA bitfields. The
  decoder supports uncompressed palette, 16-bit, 24-bit, 32-bit, and bitfield
  images; BMP RLE compression is not currently supported.
- PNG is encoded as non-interlaced 8-bit RGBA with adaptive row filters.
- JPEG is baseline JPEG with selectable 4:4:4 or 4:2:0 chroma sampling.
  Transparency is composited against white.
- JPEG XL import supports bare codestreams and ISOBMFF containers, lossless
  Modular and lossy VarDCT images, alpha, orientation, embedded matrix/TRC ICC
  profiles, and the first visible animation frame. Output is lossless Modular
  RGBA and preserves hidden RGB values.
- QOI is encoded and decoded losslessly according to the Quite OK Image
  specification.
- TGA supports color-mapped, true-color, and grayscale input, with raw or RLE
  pixel data. Output is 32-bit true-color and uses RLE by default.
- TIFF import supports little- and big-endian baseline files, eight-bit RGB,
  RGBA, grayscale, and palette pixels, strips, all eight orientations,
  horizontal prediction, and uncompressed, PackBits, or LZW data. Planar,
  tiled, JPEG-compressed, and samples wider than eight bits are not currently
  supported. Output is little-endian, chunky, eight-bit RGBA using PackBits by
  default; pass `TiffCompression.none` for uncompressed output.
- WebP is lossless VP8L and preserves alpha. Quality is intentionally not an
  option until a lossy encoder is added.

The JPEG and WebP encoder implementations contain code derived from the MIT
licensed Dart `image` package.

The JPEG XL implementation is adapted from
[`koni_jxl`](https://github.com/zenbaku/koni_jxl), released by Jonathan Urzúa
under the MIT License. Its decoding logic includes work derived from the MIT
licensed [`JXLatte`](https://github.com/Traneptora/jxlatte) project.
