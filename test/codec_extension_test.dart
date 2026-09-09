import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Verifies optional formats without importing any native package.
void main() {
  final Image image = Image.fromRgba(width: 1, height: 1, bytes: Uint8List.fromList([1, 2, 3, 255]));
  final Uint8List customBytes = Uint8List.fromList([0x43, 0x55, 0x53, 0x54]);

  tearDown(() {
    [
      _CustomFormat.custom,
      ImageFormat.jpegXl,
      ImageFormat.webp,
    ].forEach(ImageCodecRegistry.unregister);
    ImageFormatRegistry.unregister(_CustomFormat.custom);
  });

  test('custom formats and signatures exist only while registered', () {
    expect(ImageFormat.sniff(customBytes), isNull);
    expect(ImageFormatRegistry.register(_CustomFormat.custom), isTrue);
    expect(ImageFormatRegistry.register(_CustomFormat.custom), isFalse);
    expect(inspectImage(customBytes)?.iccProfile, [9, 8]);
    expect(
      () => decodeImage(customBytes),
      throwsA(isA<ImageCodecException>()),
    );
    ImageCodecRegistry.register(_TestExtension(format: _CustomFormat.custom));

    expect(ImageFormat.sniff(customBytes), _CustomFormat.custom);
    expect(ImageFormatRegistry.contains(_CustomFormat.custom), isTrue);
    expect(ImageFormatRegistry.lookup('custom'), same(_CustomFormat.custom));
    expect(
      ImageFormatRegistry.formats.indexOf(_CustomFormat.custom),
      lessThan(ImageFormatRegistry.formats.indexOf(ImageFormat.tga)),
    );
    expect(ImageFormatRegistry.formats.clear, throwsUnsupportedError);
    expect(decodeImage(customBytes).bytes, image.bytes);
    expect(encodeImage(image, format: _CustomFormat.custom), customBytes);
    expect(inspectImage(customBytes)?.iccProfile, [9, 8]);
    expect(decodeImageData(customBytes).iccProfile, [9, 8]);
    expect(
      () => decodeImageData(customBytes, maxDecodedBytes: 3),
      throwsA(isA<ImageCodecException>()),
    );
    expect(
      () => decodeImage(
        customBytes,
        options: const RasterDecodeOptions(maxPixels: 0),
      ),
      throwsRangeError,
    );
    expect(
      () => decodeImageData(customBytes, maxPixels: 0),
      throwsRangeError,
    );

    ImageCodecRegistry.unregister(_CustomFormat.custom);
    expect(inspectImage(customBytes)?.iccProfile, [9, 8]);
    ImageFormatRegistry.unregister(_CustomFormat.custom);
    expect(ImageFormat.sniff(customBytes), isNull);
    expect(() => encodeImage(image, format: _CustomFormat.custom), throwsA(isA<ImageCodecException>()));
  });

  test('encoder-only overrides replace generic decoding but leave direct codecs intact', () async {
    final _TestExtension extension = _TestExtension(format: ImageFormat.webp, supportsDecoding: false);
    final Uint8List dartBytes = const WebPCodec().encode(image);
    ImageCodecRegistry.register(extension);

    expect(
      encodeWebP(
        image,
        options: const WebPEncodeOptions(
          quality: 73,
          effort: WebPEffort.fast,
        ),
      ),
      customBytes,
    );
    expect((extension.options as WebPEncodeOptions).quality, 73);
    expect((extension.options as WebPEncodeOptions).effort, WebPEffort.fast);
    expect(
      encodeImage(
        image,
        format: ImageFormat.webp,
        options: const WebPEncodeOptions(quality: 61),
      ),
      customBytes,
    );
    expect((extension.options as WebPEncodeOptions).quality, 61);
    expect(await encodeImageWith(runSequentially, image, format: ImageFormat.webp), customBytes);
    expect(extension.options, isNull);
    expect(
      await encodeWebPWith(
        runSequentially,
        image,
        options: const WebPEncodeOptions(quality: 50),
      ),
      customBytes,
    );
    expect((extension.options as WebPEncodeOptions).quality, 50);
    expect(const WebPCodec().encode(image), dartBytes);
    expect(() => decodeImage(dartBytes), throwsA(isA<ImageCodecException>()));
    expect(() => decodeImageData(dartBytes), throwsA(isA<ImageCodecException>()));
    expect(inspectImage(dartBytes)?.width, 1);
  });

  test('JPEG XL aliases and runner helpers honor a registered encoder', () async {
    final _TestExtension extension = _TestExtension(format: ImageFormat.jpegXl, supportsDecoding: false);
    ImageCodecRegistry.register(extension);
    expect(
      encodeJxl(
        image,
        options: const JpegXlEncodeOptions(effort: JpegXlEffort.maximum),
      ),
      customBytes,
    );
    expect((extension.options as JpegXlEncodeOptions).effort, JpegXlEffort.maximum);
    expect(
      await encodeJpegXlWith(
        runSequentially,
        image,
        options: const JpegXlEncodeOptions(effort: JpegXlEffort.fast),
      ),
      customBytes,
    );
    expect((extension.options as JpegXlEncodeOptions).effort, JpegXlEffort.fast);
  });
}

/// External packages can subclass the format without changing Imcodec.
final class _CustomFormat extends ImageFormat with InspectableFormat {
  /// Creates the sole test format.
  const _CustomFormat._() : super(name: 'custom');

  /// Canonical format key shared by sniffing and registry lookups.
  static const _CustomFormat custom = _CustomFormat._();

  @override
  bool matches(Uint8List bytes) => bytes.length == 4 && bytes[0] == 0x43 && bytes[1] == 0x55 && bytes[2] == 0x53 && bytes[3] == 0x54;

  @override
  DecodedImageMetadata inspect(Uint8List bytes, int maxIccProfileBytes, int maxDescriptiveMetadataBytes) =>
      DecodedImageMetadata(width: 1, height: 1, bitsPerChannel: 8, colorModel: DecodedColorModel.rgb, iccProfile: Uint8List.fromList([9, 8]));
}

/// Small pure-Dart extension that records forwarded encoder options.
final class _TestExtension extends ImageCodecExtension<RasterEncodeOptions, RasterDecodeOptions> {
  @override
  final ImageFormat format;

  @override
  final bool supportsDecoding;

  /// Most recently supplied options.
  RasterEncodeOptions? options;

  /// Creates a format or encoder override.
  _TestExtension({required this.format, this.supportsDecoding = true});

  @override
  Uint8List encode(
    Image image, {
    RasterEncodeOptions? encodeOptions,
  }) {
    options = encodeOptions;
    return Uint8List.fromList([0x43, 0x55, 0x53, 0x54]);
  }

  @override
  Image decode(
    Uint8List bytes, {
    RasterDecodeOptions? decodeOptions,
    int? maxPixels,
  }) {
    if (decodeOptions != null && maxPixels != null) {
      throw ArgumentError('Pass either decodeOptions or maxPixels, not both');
    }
    final int resolvedMaxPixels = maxPixels ?? (decodeOptions ?? const RasterDecodeOptions()).maxPixels;
    if (resolvedMaxPixels < 1) {
      throw RangeError.range(
        resolvedMaxPixels,
        1,
        null,
        'maxPixels',
      );
    }
    return Image.fromRgba(width: 1, height: 1, bytes: Uint8List.fromList([1, 2, 3, 255]));
  }
}
