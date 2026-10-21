part of '../tiff.dart';

/// Opaque Photoshop private tags attached to a flattened TIFF raster.
///
/// PsdKit interprets and edits these payloads. Keeping them separate allows
/// Imcodec to preserve layers without depending on a document-model package.
final class TiffPhotoshopData {
  /// Byte order of the TIFF containing these tags.
  final Endian byteOrder;

  /// Tag 37724: Photoshop ImageSourceData with layer channels and metadata.
  final Uint8List? imageSourceData;

  /// Tag 34377: Photoshop image resources, normally in big-endian order.
  final Uint8List? imageResources;

  /// Copies optional tag data into immutable owned buffers.
  TiffPhotoshopData({required this.byteOrder, Uint8List? imageSourceData, Uint8List? imageResources})
    : imageSourceData = imageSourceData == null ? null : Uint8List.fromList(imageSourceData).asUnmodifiableView(),
      imageResources = imageResources == null ? null : Uint8List.fromList(imageResources).asUnmodifiableView();

  /// Whether either Photoshop private tag was present.
  bool get isNotEmpty => imageSourceData != null || imageResources != null;
}

/// Reads Photoshop metadata independently of TIFF pixel decompression.
extension TiffPhotoshopDecoder on TiffDecoder {
  /// Extracts tags 37724 and 34377 from the first image-file directory.
  TiffPhotoshopData readPhotoshopData(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const ImageCodecException('The TIFF header is truncated');
    }
    final Endian endian = _readEndian(bytes);
    final ByteData data = ByteData.sublistView(bytes);
    if (data.getUint16(2, endian) != 42) {
      throw const ImageCodecException('Invalid TIFF version');
    }
    final Map<int, _TiffField> fields = _readDirectory(bytes, data, endian, data.getUint32(4, endian));
    Uint8List? payload(int tag) {
      final _TiffField? field = fields[tag];
      if (field == null) {
        return null;
      }
      if (field.type != 1 && field.type != 7) {
        throw ImageCodecException('Photoshop TIFF tag $tag must contain bytes');
      }
      return _slice(bytes, field.offset, field.count);
    }

    return TiffPhotoshopData(byteOrder: endian, imageSourceData: payload(37724), imageResources: payload(34377));
  }
}
