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
the color type permits them.

## JPEG

JPEG output is baseline JPEG with selectable 4:4:4 or 4:2:0 chroma sampling.
The decoder accepts baseline, extended sequential, and progressive Huffman
JPEG data at any sampling ratio the format allows, and expands half-resolution
chroma with the same triangle filter reference decoders use. Transparency is
composited against white during encoding.

## JPEG XL

JPEG XL import supports bare codestreams and ISOBMFF containers, lossless
Modular and lossy VarDCT images, alpha, orientation, embedded matrix/TRC ICC
profiles, and the first visible animation frame. Output is lossless Modular
RGBA and preserves hidden RGB values. `JpegXlEffort` trades encoding speed
against output size: `fast` codes the image once, `balanced` (the default)
picks the better predictor first, and `maximum` searches every candidate.

## QOI

QOI is encoded and decoded losslessly according to the Quite OK Image
specification.

## TGA

TGA supports color-mapped, true-color, and grayscale input, with raw or RLE
pixel data. A 32-bit image whose attribute bytes are all zero is read as
opaque. Output is 32-bit true-color and uses RLE by default, with packets
confined to a single scanline as the format requires.

## TIFF

TIFF import supports little- and big-endian baseline files; RGB, RGBA,
grayscale, and palette pixels at 1, 2, 4, 8, or 16 bits per sample; strips;
all eight orientations; horizontal prediction; and uncompressed, PackBits, or
LZW data. Planar, tiled, and JPEG-compressed files are not currently
supported. Output is little-endian, chunky, eight-bit RGBA using PackBits by
default; pass `TiffCompression.none` for uncompressed output.

## WebP

WebP output supports lossless VP8L and lossy intra-frame VP8. Call
`encodeWebP` without a quality for lossless output, or pass a quality from zero
through 100 for lossy output. `WebPEffort` trades encoding
speed against prediction and coefficient search. Alpha remains lossless in a
separate WebP alpha chunk. The decoder accepts VP8, VP8 with alpha, VP8L, and
the first animation frame.
