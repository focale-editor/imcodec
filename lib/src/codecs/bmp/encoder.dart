part of '../bmp.dart';

/// Encodes RGBA pixels as a 32-bit BMP with explicit color masks.
final class BmpEncoder extends RasterEncoder {
  /// Creates a BMP encoder.
  const BmpEncoder();

  /// Encodes [image] using a top-level bitmap file and V4 information header.
  @override
  Uint8List encode(Image image) {
    const int pixelOffset = 14 + 108;
    final int pixelDataLength = image.width * image.height * 4;
    if (image.width > 0x7fffffff || image.height > 0x7fffffff || pixelDataLength > 0xffffffff - pixelOffset) {
      throw const ImageCodecException('BMP dimensions or file size exceed the format limits');
    }
    final OutputBuffer output = OutputBuffer()
      ..writeByte(0x42)
      ..writeByte(0x4d)
      ..writeUint32(pixelOffset + pixelDataLength)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(pixelOffset)
      ..writeUint32(108)
      ..writeUint32(image.width)
      ..writeUint32(image.height)
      ..writeUint16(1)
      ..writeUint16(32)
      ..writeUint32(3)
      ..writeUint32(pixelDataLength)
      ..writeUint32(2835)
      ..writeUint32(2835)
      ..writeUint32(0)
      ..writeUint32(0)
      ..writeUint32(0x00ff0000)
      ..writeUint32(0x0000ff00)
      ..writeUint32(0x000000ff)
      ..writeUint32(0xff000000)
      ..writeUint32(0x73524742);
    output.writeBytes(Uint8List(48));

    // Rows are written bottom-up into one preallocated block, which avoids a
    // bounds check and a growth check for every channel byte.
    final Uint8List source = image.bytes;
    final Uint8List rows = Uint8List(pixelDataLength);
    final int rowLength = image.width * 4;
    int target = 0;
    for (int y = image.height - 1; y >= 0; y--) {
      int offset = y * rowLength;
      final int rowEnd = offset + rowLength;
      while (offset < rowEnd) {
        rows[target] = source[offset + 2];
        rows[target + 1] = source[offset + 1];
        rows[target + 2] = source[offset];
        rows[target + 3] = source[offset + 3];
        target += 4;
        offset += 4;
      }
    }
    output.writeBytes(rows);
    return output.takeBytes();
  }
}
