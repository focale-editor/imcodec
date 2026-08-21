import 'dart:typed_data';

import 'package:imcodec/src/image.dart';

/// Internal contract shared by the synchronous encoders.
abstract class Encoder {
  /// Encodes the first frame of [image].
  Uint8List encode(Image image, {bool singleFrame = false});
}
