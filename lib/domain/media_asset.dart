import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:lyberry/domain/collection_utils.dart';
import 'package:lyberry/domain/image_inspector.dart';

/// Identifiers for the image formats Lyberry accepts.
abstract final class AssetMime {
  static const jpeg = 'image/jpeg';
  static const png = 'image/png';
  static const webp = 'image/webp';

  static const all = <String>{jpeg, png, webp};

  static bool isSupported(String mimeType) => all.contains(mimeType);
}

/// An immutable stored image.
///
/// [id] is the lowercase SHA-256 of [bytes], which makes the identity
/// content-addressed and lets duplicate imports collapse safely. The bytes are
/// copied on construction and only exposed as a read-only view.
///
/// There are exactly two ways to build one, and neither lets a caller claim
/// that unvalidated bytes are trusted:
///
/// * [MediaAsset.fromBytes] validates raw bytes and derives the SHA-256, MIME
///   type and dimensions itself. Only that closed path marks the asset as
///   verified.
/// * the public raw constructor describes bytes that came from somewhere else
///   (a hand-built object, an imported payload, or our own database row). Such
///   an asset is **not** marked verified, so the repository still checks its
///   digest, MIME type and dimensions at the write boundary.
final class MediaAsset {
  MediaAsset({
    required this.id,
    required this.mimeType,
    required Uint8List bytes,
    required this.width,
    required this.height,
  }) : _bytes = Uint8List.fromList(bytes),
       _contentVerified = false;

  /// Validates [bytes] and derives the identity from them.
  ///
  /// This is the only path that marks an asset verified: the id is the digest of
  /// the bytes, the MIME type and dimensions come from the decoded header, and
  /// the size/pixel/animation bounds are enforced before any raster is
  /// allocated. A caller cannot pass an id, MIME type or dimension of its own.
  factory MediaAsset.fromBytes(
    Uint8List bytes, {
    ImageLimits limits = const ImageLimits(),
    String field = 'image',
  }) {
    final inspected = ImageInspector.inspect(
      bytes,
      limits: limits,
      field: field,
    );
    return MediaAsset._verified(
      id: sha256.convert(bytes).toString(),
      mimeType: inspected.mimeType,
      bytes: bytes,
      width: inspected.width,
      height: inspected.height,
    );
  }

  MediaAsset._verified({
    required this.id,
    required this.mimeType,
    required Uint8List bytes,
    required this.width,
    required this.height,
  }) : _bytes = Uint8List.fromList(bytes),
       _contentVerified = true;

  final String id;
  final String mimeType;
  final int width;
  final int height;

  final Uint8List _bytes;
  final bool _contentVerified;

  /// True only for assets produced by [MediaAsset.fromBytes].
  bool get contentVerified => _contentVerified;

  /// Read-only view; mutating it throws [UnsupportedError].
  Uint8List get bytes => _bytes.asUnmodifiableView();

  int get byteSize => _bytes.length;

  /// Portable backup representation; phase 2 export/import uses this shape.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'mimeType': mimeType,
    'dataBase64': base64Encode(bytes),
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MediaAsset &&
        other.id == id &&
        other.mimeType == mimeType &&
        other.width == width &&
        other.height == height &&
        orderedListEquals<int>(other.bytes, bytes);
  }

  @override
  int get hashCode =>
      Object.hash(id, mimeType, width, height, orderedListHash<int>(bytes));

  @override
  String toString() =>
      'MediaAsset($id, $mimeType, ${width}x$height, $byteSize bytes)';
}
