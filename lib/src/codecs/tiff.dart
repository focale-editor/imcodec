/// Encodes and decodes Tagged Image File Format images synchronously.
library;

import 'dart:typed_data';

import 'package:imcodec/src/codecs/raster_codec.dart';
import 'package:imcodec/src/image.dart';
import 'package:imcodec/src/image_codec_exception.dart';
import 'package:imcodec/src/image_format.dart';

part 'tiff/codec.dart';
part 'tiff/decoder.dart';
part 'tiff/encoder.dart';
