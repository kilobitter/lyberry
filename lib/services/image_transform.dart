import 'package:flutter/foundation.dart';
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/cover_renderer.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';

/// Runs the bounded decode/transform/encode jobs behind [ImageTransformService].
///
/// The production worker hands each job to a background isolate so a 20 MP
/// decode never blocks the UI thread; the inline worker runs the identical
/// pixel code on the calling isolate and exists for tests.
abstract interface class ImageRenderWorker {
  Future<CoverPreview> preparePreview({
    required Uint8List source,
    required ImageLimits limits,
    required int maxDimension,
  });

  Future<CoverPreview> rotatePreview({
    required Uint8List preview,
    required int quarterTurns,
  });

  /// Renders the derived cover and validates it into a verified [MediaAsset]
  /// on the same isolate the pixels were produced on.
  Future<MediaAsset> renderCover({
    required Uint8List source,
    required CoverCrop crop,
    required ImageLimits limits,
    required int maxDimension,
    required int jpegQuality,
    required String field,
  });
}

/// Production worker: every raster job runs off the Flutter UI thread.
class IsolateImageRenderWorker implements ImageRenderWorker {
  const IsolateImageRenderWorker();

  @override
  Future<CoverPreview> preparePreview({
    required Uint8List source,
    required ImageLimits limits,
    required int maxDimension,
  }) {
    return compute(_preparePreviewEntry, <Object?>[
      source,
      limits.maxBytes,
      limits.maxPixels,
      maxDimension,
    ]);
  }

  @override
  Future<CoverPreview> rotatePreview({
    required Uint8List preview,
    required int quarterTurns,
  }) {
    return compute(_rotatePreviewEntry, <Object?>[preview, quarterTurns]);
  }

  @override
  Future<MediaAsset> renderCover({
    required Uint8List source,
    required CoverCrop crop,
    required ImageLimits limits,
    required int maxDimension,
    required int jpegQuality,
    required String field,
  }) {
    return compute(_renderCoverEntry, <Object?>[
      source,
      crop.left,
      crop.top,
      crop.width,
      crop.height,
      crop.quarterTurns,
      limits.maxBytes,
      limits.maxPixels,
      maxDimension,
      jpegQuality,
      field,
    ]);
  }
}

/// Runs the same pixel code synchronously, for widgets tests and for platforms
/// without a usable isolate. Never used by the app in production.
class InlineImageRenderWorker implements ImageRenderWorker {
  const InlineImageRenderWorker();

  @override
  Future<CoverPreview> preparePreview({
    required Uint8List source,
    required ImageLimits limits,
    required int maxDimension,
  }) async {
    return CoverRenderer.preparePreview(
      source: source,
      limits: limits,
      maxDimension: maxDimension,
    );
  }

  @override
  Future<CoverPreview> rotatePreview({
    required Uint8List preview,
    required int quarterTurns,
  }) async {
    return CoverRenderer.rotatePreview(
      preview: preview,
      quarterTurns: quarterTurns,
    );
  }

  @override
  Future<MediaAsset> renderCover({
    required Uint8List source,
    required CoverCrop crop,
    required ImageLimits limits,
    required int maxDimension,
    required int jpegQuality,
    required String field,
  }) async {
    return CoverRenderer.deriveCoverAsset(
      source: source,
      crop: crop,
      limits: limits,
      maxDimension: maxDimension,
      jpegQuality: jpegQuality,
      field: field,
    );
  }
}

/// Turns a personal photo into a separate, validated cover asset.
///
/// The source bytes are never modified and never uploaded: the derived cover is
/// a brand new content-addressed [MediaAsset], so the original photo keeps its
/// identity and can be cropped again from the untouched original.
class ImageTransformService {
  const ImageTransformService({
    this.worker = const IsolateImageRenderWorker(),
    this.limits = const ImageLimits(),
    this.maxOutputDimension = CoverRenderer.maxOutputDimension,
    this.jpegQuality = CoverRenderer.outputJpegQuality,
  });

  final ImageRenderWorker worker;
  final ImageLimits limits;
  final int maxOutputDimension;
  final int jpegQuality;

  /// The orientation-corrected preview of the whole photo, no extra rotation.
  Future<CoverPreview> preview(Uint8List source) {
    return worker.preparePreview(
      source: source,
      limits: limits,
      maxDimension: CoverRenderer.maxPreviewDimension,
    );
  }

  /// Rotates an already oriented preview by [quarterTurns] clockwise.
  Future<CoverPreview> rotate(Uint8List preview, int quarterTurns) {
    return worker.rotatePreview(preview: preview, quarterTurns: quarterTurns);
  }

  /// Renders and validates the derived cover.
  ///
  /// The render, the decode of the encoded output, the SHA-256 and the bound
  /// check all run inside [worker] - the background isolate in the app - so no
  /// part of a large JPEG decode touches the UI thread. The returned asset comes
  /// from [MediaAsset.fromBytes], so the repository's verified-content
  /// optimization still applies.
  Future<MediaAsset> deriveCover({
    required Uint8List source,
    required CoverCrop crop,
    String field = 'cover',
  }) async {
    // Cheap model validation on the caller gives the caller a Future error
    // (the API stays awaitable) and keeps a bad rectangle out of the isolate.
    // The decode, digest and bound check all run inside the worker.
    crop.assertValid(field: field);
    return worker.renderCover(
      source: source,
      crop: crop,
      limits: limits,
      maxDimension: maxOutputDimension,
      jpegQuality: jpegQuality,
      field: field,
    );
  }
}

CoverPreview _preparePreviewEntry(List<Object?> message) =>
    CoverRenderer.preparePreview(
      source: message[0]! as Uint8List,
      limits: ImageLimits(
        maxBytes: message[1]! as int,
        maxPixels: message[2]! as int,
      ),
      maxDimension: message[3]! as int,
    );

CoverPreview _rotatePreviewEntry(List<Object?> message) =>
    CoverRenderer.rotatePreview(
      preview: message[0]! as Uint8List,
      quarterTurns: message[1]! as int,
    );

MediaAsset _renderCoverEntry(List<Object?> message) =>
    CoverRenderer.deriveCoverAsset(
      source: message[0]! as Uint8List,
      crop: CoverCrop(
        left: message[1]! as double,
        top: message[2]! as double,
        width: message[3]! as double,
        height: message[4]! as double,
        quarterTurns: message[5]! as int,
      ),
      limits: ImageLimits(
        maxBytes: message[6]! as int,
        maxPixels: message[7]! as int,
      ),
      maxDimension: message[8]! as int,
      jpegQuality: message[9]! as int,
      field: message[10]! as String,
    );
