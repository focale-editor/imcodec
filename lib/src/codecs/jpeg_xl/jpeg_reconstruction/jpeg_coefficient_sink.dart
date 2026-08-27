import 'dart:typed_data';

/// Collects quantized coefficients while decoding a JPEG-transcoded frame.
/// Each component uses block-raster order and natural coefficient order, which
/// is the representation consumed by the JPEG reconstruction writer.
final class JpegCoefficientSink {
  /// Width of each component coefficient plane in 8 × 8 blocks.
  final List<int> widthInBlocks;

  /// Height of each component coefficient plane in 8 × 8 blocks.
  final List<int> heightInBlocks;

  /// Flat natural-order coefficients for every block of each component.
  final List<Int32List> coefficients;

  /// Per JPEG component, the raw signed chroma-from-luma factor of each block's
  /// 64x64 color tile (X-from-Y for Cb, B-from-Y for Cr; 0 for luma). Used to
  /// invert CfL on 4:4:4 chroma AC during reconstruction.
  final List<Int32List> chromaFromLumaFactors;

  /// Set if any captured block uses a transform other than DCT 8x8. JPEG only
  /// has 8x8 blocks, so a transcode never does; a crafted `.jxl` might, and
  /// reconstruction rejects it rather than emitting wrong bytes.
  bool containsNonDct8 = false;

  /// Creates storage for component planes with the supplied block dimensions.
  JpegCoefficientSink({
    required this.widthInBlocks,
    required this.heightInBlocks,
  }) : coefficients = [for (var i = 0; i < widthInBlocks.length; i++) Int32List(widthInBlocks[i] * heightInBlocks[i] * 64)],
       chromaFromLumaFactors = [for (var i = 0; i < widthInBlocks.length; i++) Int32List(widthInBlocks[i] * heightInBlocks[i])];

  /// Records the per-tile CfL factor for one block.
  void setChromaFromLumaFactor(int componentIndex, int blockY, int blockX, int factor) {
    if (componentIndex >= coefficients.length) {
      return;
    }
    final int blockWidth = widthInBlocks[componentIndex];
    if (blockX >= blockWidth || blockY >= heightInBlocks[componentIndex]) {
      return;
    }
    chromaFromLumaFactors[componentIndex][blockY * blockWidth + blockX] = factor;
  }

  /// Records the quantized DC integer for one block (natural position 0).
  void setDcCoefficient(int componentIndex, int blockY, int blockX, int value) {
    if (componentIndex >= coefficients.length) {
      return;
    }
    final int blockWidth = widthInBlocks[componentIndex];
    if (blockX >= blockWidth || blockY >= heightInBlocks[componentIndex]) {
      return;
    }
    coefficients[componentIndex][(blockY * blockWidth + blockX) * 64] = value;
  }

  /// Copies a block's AC coefficients from a group coefficient plane.
  /// The DC slot remains untouched for [setDcCoefficient].
  void setAcCoefficients(int componentIndex, int blockY, int blockX, Float32List quantizedCoefficients, int pixelY, int pixelX, int coefficientWidth) {
    if (componentIndex >= coefficients.length) {
      return;
    }
    final int blockWidth = widthInBlocks[componentIndex];
    if (blockX >= blockWidth || blockY >= heightInBlocks[componentIndex]) {
      return;
    }
    final int destinationOffset = (blockY * blockWidth + blockX) * 64;
    final Int32List destination = coefficients[componentIndex];
    for (int row = 0; row < 8; row++) {
      final int sourceRowOffset = (pixelY + row) * coefficientWidth + pixelX;
      final int destinationRowOffset = destinationOffset + row * 8;
      for (int column = 0; column < 8; column++) {
        if (row == 0 && column == 0) {
          continue; // DC comes from setDcCoefficient.
        }
        destination[destinationRowOffset + column] = quantizedCoefficients[sourceRowOffset + column].toInt();
      }
    }
  }
}
