/// Encodes and decodes bounded single-part OpenEXR scan-line images.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:imcodec/src/codecs/exception.dart';
import 'package:imcodec/src/codecs/raster_codec.dart';
import 'package:imcodec/src/decoded_image.dart';
import 'package:imcodec/src/formats/image_format.dart';
import 'package:imcodec/src/image.dart';
import 'package:zcodec/zcodec.dart';

part 'open_exr/codec.dart';
part 'open_exr/decoder.dart';
part 'open_exr/encoder.dart';
