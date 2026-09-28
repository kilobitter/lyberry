import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/validation.dart';

/// A decoded, bounded preview of a photo in one orientation.
///
/// [bytes] is a JPEG that already has the EXIF orientation baked in and the
/// requested quarter turns applied, so painting it 1:1 matches the image space
/// the crop rectangle is expressed in. [width] and [height] are its pixel size.
class CoverPreview {
  const CoverPreview({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  double get aspectRatio => width / height;
}

/// Decodes, orients, rotates, crops and re-encodes a cover.
///
/// Every step is pure Dart so it can run inside a background isolate (the
/// service wraps it) and so the pixel behaviour is testable without Flutter.
/// The order is fixed and shared by the preview and the saved cover:
/// validate headers, bake the EXIF orientation once, apply the quarter turns,
/// crop in that oriented space, bound the result and drop metadata.
abstract final class CoverRenderer {
  /// Longest side of a saved cover; matches the camera's own 2560 cap.
  static const int maxOutputDimension = 2560;

  /// Longest side of an interactive preview raster.
  static const int maxPreviewDimension = 1280;

  static const int outputJpegQuality = 88;
  static const int previewJpegQuality = 85;

  /// Bakes the EXIF orientation and returns a bounded preview of the whole
  /// photo with no extra rotation.
  static CoverPreview preparePreview({
    required Uint8List source,
    ImageLimits limits = const ImageLimits(),
    int maxDimension = maxPreviewDimension,
  }) {
    final image = _decodeOriented(source, limits: limits);
    final bounded = _bound(image, maxDimension);
    bounded.exif = img.ExifData();
    bounded.iccProfile = null;
    return CoverPreview(
      bytes: img.encodeJpg(bounded, quality: previewJpegQuality),
      width: bounded.width,
      height: bounded.height,
    );
  }

  /// Rotates an already oriented preview by [quarterTurns] clockwise, without
  /// compounding loss: the caller always passes the unrotated preview.
  static CoverPreview rotatePreview({
    required Uint8List preview,
    required int quarterTurns,
  }) {
    final turns = _normalizedTurns(quarterTurns);
    final decoded = _decode(preview);
    final rotated = turns == 0
        ? decoded
        : img.copyRotate(decoded, angle: turns * 90);
    rotated.exif = img.ExifData();
    rotated.iccProfile = null;
    return CoverPreview(
      bytes: img.encodeJpg(rotated, quality: previewJpegQuality),
      width: rotated.width,
      height: rotated.height,
    );
  }

  /// Renders the saved cover bytes for [crop].
  ///
  /// Throws [ValidationException] for an invalid rectangle or an unreadable
  /// source, never a partially encoded image.
  static Uint8List renderCover({
    required Uint8List source,
    required CoverCrop crop,
    ImageLimits limits = const ImageLimits(),
    int maxDimension = maxOutputDimension,
    int jpegQuality = outputJpegQuality,
  }) {
    crop.assertValid();
    final image = _decodeOriented(source, limits: limits);
    final turns = _normalizedTurns(crop.quarterTurns);
    final oriented = turns == 0
        ? image
        : img.copyRotate(image, angle: turns * 90);

    final pixels = crop.toPixels(
      imageWidth: oriented.width,
      imageHeight: oriented.height,
    );
    final cropped = img.copyCrop(
      oriented,
      x: pixels.x,
      y: pixels.y,
      width: pixels.width,
      height: pixels.height,
    );
    final bounded = _bound(cropped, maxDimension);
    // Re-encoding through a fresh image is what keeps the cover free of the
    // source's capture and location metadata.
    bounded.exif = img.ExifData();
    bounded.iccProfile = null;
    return img.encodeJpg(bounded, quality: jpegQuality);
  }

  /// Renders the cover and turns it into a verified [MediaAsset] in one step.
  ///
  /// Both workers call this, so the final decode, digest and bound check happen
  /// wherever the pixels ran - in the isolate for the app - and the asset still
  /// comes from the canonical [MediaAsset.fromBytes] path. Nothing here hands
  /// out raw bytes that a caller could mark trusted.
  static MediaAsset deriveCoverAsset({
    required Uint8List source,
    required CoverCrop crop,
    ImageLimits limits = const ImageLimits(),
    int maxDimension = maxOutputDimension,
    int jpegQuality = outputJpegQuality,
    String field = 'cover',
  }) {
    final bytes = renderCover(
      source: source,
      crop: crop,
      limits: limits,
      maxDimension: maxDimension,
      jpegQuality: jpegQuality,
    );
    return MediaAsset.fromBytes(bytes, limits: limits, field: field);
  }

  /// Header bounds are checked before any raster is allocated, then the single
  /// decode is the one the inspector already validated.
  static img.Image _decodeOriented(
    Uint8List source, {
    required ImageLimits limits,
  }) {
    // The canonical safety path, unchanged: byte, container, animation, chunk
    // and pixel bounds before the decode, plus the header/raster agreement
    // check that now understands an honest EXIF quarter turn.
    ImageInspector.inspect(source, limits: limits, field: 'cover');
    final decoded = _decode(source);
    return img.bakeOrientation(decoded);
  }

  static img.Image _decode(Uint8List bytes) {
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } on Object {
      throw ValidationException([
        const ValidationIssue('cover', 'That photo could not be opened.'),
      ]);
    }
    if (decoded == null) {
      throw ValidationException([
        const ValidationIssue('cover', 'That photo could not be opened.'),
      ]);
    }
    return decoded;
  }

  /// Downscales only when the longest side exceeds [maxDimension].
  static img.Image _bound(img.Image image, int maxDimension) {
    if (image.width <= maxDimension && image.height <= maxDimension) {
      return image;
    }
    return image.width >= image.height
        ? img.copyResize(
            image,
            width: maxDimension,
            interpolation: img.Interpolation.linear,
          )
        : img.copyResize(
            image,
            height: maxDimension,
            interpolation: img.Interpolation.linear,
          );
  }

  static int _normalizedTurns(int quarterTurns) => ((quarterTurns % 4) + 4) % 4;
}
