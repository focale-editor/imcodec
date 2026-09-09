# Format behavior

## BMP

BMP is encoded as a V4 32-bit bitmap with explicit RGBA bitfields. The
decoder supports uncompressed palette, 16-bit, 24-bit, 32-bit, and bitfield
images, as well as RLE4 and RLE8 compressed palette images.

## GIF

GIF output is one non-interlaced GIF89a frame with a global colour table,
LZW-compressed indices, and optional binary transparency. Palette reduction is
shared with PNG-8 and supports two through 256 colours, a configurable matte,
an alpha threshold, and a proportional Floyd–Steinberg dither. The decoder
accepts GIF87a and GIF89a, global or local colour tables, interlacing, and
returns the first visible frame.

## PNG

PNG is encoded as non-interlaced 8-bit RGBA with adaptive row filters. The
decoder accepts standard grayscale, true-color, indexed, grayscale-alpha,
and RGBA images, including Adam7 interlacing and 1- to 16-bit samples where
the color type permits them. `decodeImageData` retains exact unsigned 16-bit
samples, and `inspectImage` extracts bounded `iCCP`, `eXIf`, and standardized
XMP `iTXt` data.

## JPEG

JPEG output is baseline JPEG with selectable 4:4:4 or 4:2:0 chroma sampling.
The decoder accepts baseline, extended sequential, and progressive Huffman
JPEG data at any sampling ratio the format allows, and expands half-resolution
chroma with the same triangle filter reference decoders use. Transparency is
composited against white during encoding. The metadata-aware decoder retains
Adobe CMYK or YCCK files as CMYK+A instead of flattening them to RGB, and
reassembles ordered APP2 ICC segments. Inspection also retains standard APP1
EXIF and XMP payloads plus the IPTC-IIM resource of a Photoshop APP13 segment.

## JPEG XL

JPEG XL import supports bare codestreams and ISOBMFF containers, lossless
Modular and lossy VarDCT images, alpha, orientation, embedded matrix/TRC ICC
profiles, and the first visible animation frame. Output is lossless Modular
RGBA and preserves hidden RGB values. `JpegXlEffort` trades encoding speed
against output size: `fast` codes the image once, `balanced` (the default)
picks the better predictor first, and `maximum` searches every candidate.

## OpenEXR

OpenEXR import reads one scan-line image part with RGB, RGBA, or luminance
channels. Half, float, and unsigned-integer channel samples are returned as
straight float32 RGBA by `decodeOpenExrData`; extra channels are skipped without
allocating planes for them. Authored chromaticities are adapted to sRGB
primaries, then encoded with the extended sRGB transfer function so highlights
above one remain representable in the shared `DecodedImage` contract.

The decoder supports uncompressed, RLE, ZIPS, and ZIP scan-line blocks in
increasing-Y order. It rejects decreasing/random line order, tiled, deep,
multipart, subsampled-channel, PIZ, PXR24, B44/B44A, and DWAA/DWAB inputs
explicitly. Pixel count and decoded-byte limits are checked before the float
output is allocated. Finite negative colour values and highlights above one
remain representable. Expanded scan-line blocks, including arbitrary extra
channels, share the same byte budget so hostile headers cannot request an
unbounded temporary buffer.

Output is a single-part scan-line file with half-float A, B, G, and R channels,
sRGB chromaticities, and ZIP compression by default. `OpenExrCompression`
also exposes uncompressed and ZIPS output. `encodeOpenExrFloat32Rgba` accepts
straight extended-sRGB values and converts colour channels to scene-linear
light without clipping highlights; alpha is limited to zero through one.

## QOI

QOI is encoded and decoded losslessly according to the Quite OK Image
specification.

## TGA

TGA supports color-mapped, true-color, and grayscale input, with raw or RLE
pixel data. A 32-bit image whose attribute bytes are all zero is read as
opaque. Output is 32-bit true-color and uses RLE by default, with packets
confined to a single scanline as the format requires.

## TIFF

TIFF import supports little- and big-endian baseline files; RGB, RGBA, CMYK,
grayscale, and palette pixels at 1, 2, 4, 8, or 16 unsigned bits per sample;
32-bit floating-point RGB/CMYK data; strips; all eight orientations;
horizontal prediction for 8- and 16-bit integers; and uncompressed, PackBits,
or LZW data. `decodeImageData` retains 16-bit and float32 samples, process CMYK
channels, and a bounded ICC tag. Planar, tiled, signed, double-precision, and
JPEG-compressed files are not currently supported. Inspection also retains
bounded IPTC and XMP tags without parsing them. Output is little-endian, chunky,
eight-bit RGBA using PackBits by default; pass `TiffCompression.none` for
uncompressed output.

## WebP

WebP output supports lossless VP8L and lossy intra-frame VP8. Call
`encodeWebP` without a quality for lossless output, or pass a quality from zero
through 100 for lossy output. `WebPEffort` trades encoding
speed against prediction and coefficient search. Alpha remains lossless in a
separate WebP alpha chunk. The decoder accepts VP8, VP8 with alpha, VP8L, and
the first animation frame. `inspectImage` also returns top-level ICCP, EXIF, and
XMP chunks.


# Optional formats and encoder replacements

Imcodec stays pure Dart. Add-on packages can extend `ImageFormat` and register
an `ImageCodecExtension`, without adding a dependency to Imcodec itself:

```dart
final class CustomFormat extends ImageFormat with InspectableFormat {
  const CustomFormat() : super(name: 'custom');

  @override
  bool matches(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x43 &&
      bytes[1] == 0x55 &&
      bytes[2] == 0x53 &&
      bytes[3] == 0x54;

  @override
  DecodedImageMetadata inspect(
    Uint8List bytes,
    int maxIccProfileBytes,
    int maxDescriptiveMetadataBytes,
  ) => DecodedImageMetadata(
    width: 1,
    height: 1,
    bitsPerChannel: 8,
    colorModel: DecodedColorModel.rgb,
  );
}

const ImageFormat custom = CustomFormat();
// ImageFormatRegistry.register(custom);
// ImageCodecRegistry.register(MyCodecExtension(format: custom));
// ImageFormat.sniff(bytes), decodeImage and encodeImage then use the extension.
```

Every format supplies its own signature matcher and may implement
`InspectableFormat` to expose bounded container metadata independently from
its codec. `ImageFormat.sniff` iterates
the ordered `ImageFormatRegistry.formats` collection, which initially contains
all pure-Dart formats. Add-ons register their formats explicitly and may use a
higher or lower sniff priority when signatures overlap. Codec implementations
are registered separately and may supply an encoder and decoder. Both
registries are explicit and local to each isolate. A registered extension is
authoritative for the complete generic codec entry: an encoder-only extension
also makes generic decoding unavailable until it is unregistered. Direct codec
instances stay unchanged, and unregistering restores the built-in entry.

`imcodec_native` uses this API for AVIF/HEIF and native JPEG XL/WebP encoders,
with the same engines compiled to WebAssembly for browsers. Applications that
do not add and initialize that package retain their pure-Dart behavior.

Since 0.4.0, `ImageFormat` is an extensible class, not an enum. Its existing
constants, `name` and `sniff` remain available. Use
`ImageFormatRegistry.formats` instead of `ImageFormat.values`, and
`ImageFormatRegistry.lookup(name)` instead of `values.byName`. The registry is
dynamic and includes installed add-on formats. Enum `index` and exhaustive
switches are no longer available; use `name` for application-owned
serialization and add a fallback to switches.
