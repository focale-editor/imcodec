/// Encodes and decodes Tagged Image File Format images synchronously.
library;

import 'dart:typed_data';

import 'package:imcodec/src/codecs/exception.dart';
import 'package:imcodec/src/codecs/raster_codec.dart';
import 'package:imcodec/src/decoded_image.dart';
import 'package:imcodec/src/formats/image_format.dart';
import 'package:imcodec/src/image.dart';

part 'tiff/codec.dart';
part 'tiff/decoder.dart';
part 'tiff/encoder.dart';
