import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/cover_renderer.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:lyberry/services/image_transform.dart';

import '../support/photo_fixtures.dart';

void main() {
  const inline = ImageTransformService(worker: InlineImageRenderWorker());

  group('ImageTransformService.deriveCover', () {
    test('wraps the renderer without changing a byte', () async {
      final source = quadJpeg();
      const crop = CoverCrop(left: 0.25, top: 0.25, width: 0.5, height: 0.5);
      final asset = await inline.deriveCover(source: source, crop: crop);
      final direct = CoverRenderer.renderCover(source: source, crop: crop);
      expect(asset.bytes, orderedEquals(direct));
      expect(asset.mimeType, AssetMime.jpeg);
      expect(asset.contentVerified, isTrue);
    });

    test(
      'the isolate worker derives the same cover as the inline worker',
      () async {
        final source = quadJpeg();
        const crop = CoverCrop(left: 0.5, top: 0, width: 0.5, height: 1);
        final isolated = await const ImageTransformService().deriveCover(
          source: source,
          crop: crop,
        );
        final direct = await inline.deriveCover(source: source, crop: crop);
        expect(isolated.id, direct.id);
        expect(isolated.width, direct.width);
        expect(isolated.height, direct.height);
        // The final decode, digest and bound check ran inside the isolate, and
        // the verified flag survived the trip back.
        expect(isolated.contentVerified, isTrue);
      },
    );

    test(
      'an EXIF original ingests raw and crops to the oriented frame',
      () async {
        final bytes = quadJpeg(orientation: 6);
        final photo = const ImageIngest().buildAsset(bytes);
        // Ingest keeps the stored, un-rotated dimensions...
        expect(photo.width, 240);
        expect(photo.height, 120);
        expect(photo.contentVerified, isTrue);

        // ...and the crop pipeline works from those untouched bytes.
        final preview = await inline.preview(photo.bytes);
        expect(preview.width, 120);
        expect(preview.height, 240);
        final cover = await inline.deriveCover(
          source: photo.bytes,
          crop: CoverCrop.full,
        );
        expect(cover.width, 120);
        expect(cover.height, 240);
        expect(cover.contentVerified, isTrue);
      },
    );

    test('never mutates the source bytes', () async {
      final source = quadJpeg();
      final before = Uint8List.fromList(source);
      await inline.deriveCover(
        source: source,
        crop: const CoverCrop(left: 0.2, top: 0.2, width: 0.6, height: 0.6),
      );
      expect(source, orderedEquals(before));
    });

    test(
      'a different crop derives a different content-addressed cover',
      () async {
        final source = quadJpeg();
        final first = await inline.deriveCover(
          source: source,
          crop: const CoverCrop(left: 0, top: 0, width: 0.5, height: 1),
        );
        final second = await inline.deriveCover(
          source: source,
          crop: const CoverCrop(left: 0.5, top: 0, width: 0.5, height: 1),
        );
        final again = await inline.deriveCover(
          source: source,
          crop: const CoverCrop(left: 0, top: 0, width: 0.5, height: 1),
        );
        expect(first.id, isNot(second.id));
        expect(first.id, again.id);
      },
    );
  });

  group('real pixels', () {
    test(
      'a dragged crop changes the saved pixels, not just the overlay',
      () async {
        final source = quadJpeg();
        final rightHalf = await inline.deriveCover(
          source: source,
          crop: const CoverCrop(left: 0.5, top: 0, width: 0.5, height: 1),
        );
        final image = decodeBytes(rightHalf.bytes);
        expect(image.width, 120);
        expect(image.height, 120);
        expect(
          isNearColour(pixelAt(image, 30, 30), 30, 200, 30),
          isTrue,
          reason: 'top-left of the crop is the green quadrant',
        );
        expect(
          isNearColour(pixelAt(image, 90, 90), 230, 210, 40),
          isTrue,
          reason: 'bottom-right of the crop is the yellow quadrant',
        );
      },
    );

    test('quarter turns rotate the saved pixels clockwise', () async {
      final source = quadJpeg();
      final clockwise = decodeBytes(
        (await inline.deriveCover(
          source: source,
          crop: const CoverCrop(quarterTurns: 1),
        )).bytes,
      );
      expect(clockwise.width, 120);
      expect(clockwise.height, 240);
      expect(
        isNearColour(pixelAt(clockwise, 30, 60), 30, 30, 220),
        isTrue,
        reason: 'the old bottom-left corner becomes top-left',
      );

      final anticlockwise = decodeBytes(
        (await inline.deriveCover(
          source: source,
          crop: const CoverCrop(quarterTurns: 3),
        )).bytes,
      );
      expect(
        isNearColour(pixelAt(anticlockwise, 30, 60), 30, 200, 30),
        isTrue,
        reason: 'three turns put the old top-right corner top-left',
      );
    });

    test(
      'EXIF orientation is normalized once for preview and output',
      () async {
        final source = quadJpeg(orientation: 6);
        expect(declaredSize(source), (width: 240, height: 120));
        expect(exifOrientation(source), 6);

        final preview = await inline.preview(source);
        expect(preview.width, 120);
        expect(preview.height, 240);

        final cover = await inline.deriveCover(
          source: source,
          crop: CoverCrop.full,
        );
        expect(cover.width, preview.width);
        expect(cover.height, preview.height);

        final previewPixels = decodeBytes(preview.bytes);
        final coverPixels = decodeBytes(cover.bytes);
        expect(
          isNearColour(pixelAt(coverPixels, 30, 60), 30, 30, 220),
          isTrue,
          reason: 'the oriented top-left is the old bottom-left quadrant',
        );
        expect(
          isNearColour(pixelAt(coverPixels, 90, 180), 30, 200, 30),
          isTrue,
          reason: 'the oriented bottom-right is the old top-right quadrant',
        );
        expect(
          _gridsAgree(previewPixels, coverPixels),
          isTrue,
          reason: 'preview and saved cover show the same image',
        );
      },
    );

    test('an EXIF-rotated crop is applied in the oriented space', () async {
      final source = quadJpeg(orientation: 6);
      final topHalf = decodeBytes(
        (await inline.deriveCover(
          source: source,
          crop: const CoverCrop(left: 0, top: 0, width: 1, height: 0.5),
        )).bytes,
      );
      expect(topHalf.width, 120);
      expect(topHalf.height, 120);
      expect(isNearColour(pixelAt(topHalf, 30, 60), 30, 30, 220), isTrue);
      expect(isNearColour(pixelAt(topHalf, 90, 60), 220, 30, 30), isTrue);
    });

    test('a rotated preview matches the rotated output', () async {
      final source = quadJpeg(width: 400, height: 200);
      final oriented = await inline.preview(source);
      final rotated = await inline.rotate(oriented.bytes, 1);
      expect(rotated.width, 200);
      expect(rotated.height, 400);
      final cover = await inline.deriveCover(
        source: source,
        crop: const CoverCrop(quarterTurns: 1),
      );
      expect(
        _gridsAgree(decodeBytes(rotated.bytes), decodeBytes(cover.bytes)),
        isTrue,
      );
    });
  });

  group('bounds, metadata and rejection', () {
    test('a large source is bounded to 2560 on its longest side', () async {
      final source = quadJpeg(width: 3200, height: 2400, quality: 70);
      final cover = await inline.deriveCover(
        source: source,
        crop: CoverCrop.full,
      );
      expect(cover.width, 2560);
      expect(cover.height, 1920);
      expect(cover.byteSize, lessThanOrEqualTo(FieldLimits.maxAssetBytes));
    });

    test('a small source is never upscaled', () async {
      final cover = await inline.deriveCover(
        source: quadJpeg(width: 200, height: 400),
        crop: CoverCrop.full,
      );
      expect(cover.width, 200);
      expect(cover.height, 400);
    });

    test('the derived cover carries no EXIF block', () async {
      final source = quadJpeg(orientation: 6);
      final cover = await inline.deriveCover(
        source: source,
        crop: CoverCrop.full,
      );
      expect(exifOrientation(cover.bytes), isNull);
      final image = decodeBytes(cover.bytes);
      expect(image.exif.imageIfd.hasOrientation, isFalse);
      expect(image.exif.isEmpty, isTrue);
    });

    test('empty, non-finite and out-of-bounds crops are rejected', () async {
      final source = quadJpeg();
      for (final crop in <CoverCrop>[
        const CoverCrop(width: 0),
        const CoverCrop(height: 0),
        const CoverCrop(width: double.nan),
        const CoverCrop(left: 0.8, width: 0.4),
        const CoverCrop(top: -0.5),
        const CoverCrop(quarterTurns: 4),
      ]) {
        await expectLater(
          inline.deriveCover(source: source, crop: crop),
          throwsA(isA<ValidationException>()),
          reason: '$crop',
        );
      }
    });

    test('non-image bytes are rejected with a usable error', () async {
      final notAnImage = Uint8List.fromList(List<int>.filled(128, 9));
      await expectLater(
        inline.deriveCover(source: notAnImage, crop: CoverCrop.full),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.issues.first.message,
            'message',
            contains('JPEG, PNG or WebP'),
          ),
        ),
      );
    });

    test('the pixel bound is enforced before any raster work', () async {
      const tight = ImageTransformService(
        worker: InlineImageRenderWorker(),
        limits: ImageLimits(maxPixels: 1000),
      );
      await expectLater(
        tight.deriveCover(source: quadJpeg(), crop: CoverCrop.full),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.issues.first.message,
            'message',
            contains('20 megapixels'),
          ),
        ),
      );
    });

    test('the byte bound is enforced before any raster work', () async {
      const tight = ImageTransformService(
        worker: InlineImageRenderWorker(),
        limits: ImageLimits(maxBytes: 64),
      );
      await expectLater(
        tight.deriveCover(source: quadJpeg(), crop: CoverCrop.full),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.issues.first.message,
            'message',
            contains('5 MiB'),
          ),
        ),
      );
    });
  });
}

/// Compares two images on a coarse grid, tolerating JPEG re-encode noise.
bool _gridsAgree(img.Image a, img.Image b) {
  if (a.width != b.width || a.height != b.height) return false;
  for (var y = 8; y < a.height; y += 24) {
    for (var x = 8; x < a.width; x += 24) {
      final left = pixelAt(a, x, y);
      final right = pixelAt(b, x, y);
      if (!isNearColour(left, right.r, right.g, right.b, tolerance: 40)) {
        return false;
      }
    }
  }
  return true;
}
