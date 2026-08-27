/// Encodes and decodes WebP images synchronously.
/// Encoding produces lossless VP8L or lossy VP8 data. Decoding accepts
/// lossless VP8L, lossy VP8, alpha data, and the first frame of animated WebP
/// files.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/raster_codec.dart';
import 'package:imcodec/src/codecs/webp/effort.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';
import 'package:imcodec/src/output_buffer.dart';
import 'package:imcodec/src/parallel_runner.dart';

export 'webp/effort.dart';

part 'webp/alpha/decoder.dart';
part 'webp/alpha/filters.dart';
part 'webp/buffer.dart';
part 'webp/codec.dart';
part 'webp/decoder.dart';
part 'webp/encoder.dart';
part 'webp/huffman_table.dart';
part 'webp/info.dart';
part 'webp/lossy/bit_writer.dart';
part 'webp/lossy/encoder.dart';
part 'webp/lossy/tables.dart';
part 'webp/lossy/transform.dart';
part 'webp/lossy/types.dart';
part 'webp/utilities.dart';
part 'webp/vp8/bit_reader.dart';
part 'webp/vp8/decoder.dart';
part 'webp/vp8/filter.dart';
part 'webp/vp8/lossless_bit_reader.dart';
part 'webp/vp8/lossless_color_cache.dart';
part 'webp/vp8/lossless_decoder.dart';
part 'webp/vp8/lossless_transform.dart';
part 'webp/vp8/types.dart';
