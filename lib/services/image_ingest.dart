import 'dart:typed_data';

import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';

/// Turns untrusted image bytes into a validated, content-addressed [MediaAsset].
class ImageIngest {
  const ImageIngest({this.limits = const ImageLimits()});

  final ImageLimits limits;

  MediaAsset buildAsset(Uint8List bytes, {String field = 'photo'}) {
    return MediaAsset.fromBytes(bytes, limits: limits, field: field);
  }
}
