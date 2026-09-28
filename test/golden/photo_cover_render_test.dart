import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/services/image_transform.dart';
import 'package:lyberry/ui/screens/cover_crop_screen.dart';
import 'package:lyberry/ui/theme.dart';

import '../support/photo_fixtures.dart';
import '../support/test_support.dart';

// Renders the new crop preview at phone size and writes PNG evidence.
// Run with: flutter test --update-goldens test/golden
// The PNGs are copied into docs/agent-work/lyberry/evidence/photo-cover/.
void main() {
  setUpAll(loadAppFonts);

  const transform = ImageTransformService(worker: InlineImageRenderWorker());

  /// Pumps first, then waits until the stage really shows an interactive
  /// preview of [width] x [height]. Pumping before the check matters: a tap
  /// that starts a rotation only sets `_loading` on the next frame, so a
  /// readiness check that looks immediately would still see the old, enabled
  /// Apply button and capture the previous preview.
  ///
  /// [notBytes] additionally requires the stage to have swapped to different
  /// preview bytes, which is what a quarter turn must do.
  Future<CropStage> awaitPreviewStage(
    WidgetTester tester, {
    required int width,
    required int height,
    Uint8List? notBytes,
  }) async {
    final stage = find.byKey(CoverCropScreen.stageKey);
    final apply = find.byKey(CoverCropScreen.applyKey);
    for (var index = 0; index < 200; index++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (stage.evaluate().isEmpty || apply.evaluate().isEmpty) continue;
      final ready = tester.widget<FilledButton>(apply).onPressed != null;
      final preview = tester.widget<CropStage>(stage);
      final sizeMatches =
          preview.imageWidth == width && preview.imageHeight == height;
      final bytesChanged =
          notBytes == null || !_sameBytes(preview.imageBytes, notBytes);
      if (ready && sizeMatches && bytesChanged) return preview;
    }
    fail('the crop stage never showed the expected ${width}x$height preview');
  }

  /// Decodes the preview with the real engine before the golden is captured.
  ///
  /// Without this the `Image.memory` frame can still be pending, which records a
  /// blank stage, or - because the stage keeps the previous frame during a
  /// swap - an old, stretched frame after a rotation.
  Future<void> settlePreviewImage(WidgetTester tester) async {
    final stageImages = find.descendant(
      of: find.byKey(CoverCropScreen.stageKey),
      matching: find.byType(Image),
    );
    expect(stageImages, findsWidgets, reason: 'the stage shows the preview');

    final image = tester.widget<Image>(stageImages.first);
    await tester.runAsync(() async {
      await precacheImage(image.image, tester.element(stageImages.first));
    });

    // Let the decoded frame paint into the recorded layer.
    for (var index = 0; index < 4; index++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> dragBottomRight(WidgetTester tester, Offset delta) async {
    final stage = tester.getRect(find.byKey(CoverCropScreen.stageKey));
    final fitted = _fitRect(stage.size, const Size(900, 600));
    final corner =
        stage.topLeft +
        Offset(fitted.right, fitted.bottom) -
        const Offset(6, 6);
    await tester.dragFrom(corner, delta);
    await tester.pump();
  }

  testWidgets('crop preview with a dragged crop at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLyberryTheme(),
        home: CoverCropScreen(
          sourceBytes: quadJpeg(width: 900, height: 600),
          transform: transform,
        ),
      ),
    );
    await awaitPreviewStage(tester, width: 900, height: 600);
    await settlePreviewImage(tester);
    expect(tester.takeException(), isNull);

    await dragBottomRight(tester, const Offset(-150, -90));
    await settlePreviewImage(tester);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/photo_cover_crop_390x844.png'),
    );
  });

  testWidgets('crop preview after a quarter turn at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLyberryTheme(),
        home: CoverCropScreen(
          sourceBytes: quadJpeg(width: 900, height: 600),
          transform: transform,
        ),
      ),
    );
    final before = await awaitPreviewStage(tester, width: 900, height: 600);
    await settlePreviewImage(tester);

    await tester.tap(find.byKey(CoverCropScreen.rotateRightKey));
    // Let the busy state apply before waiting for the rotated preview.
    await tester.pump();

    // The stage must really hold the rotated 600x900 preview bytes before the
    // golden is recorded; otherwise the old 900x600 frame is stretched.
    final rotated = await awaitPreviewStage(
      tester,
      width: 600,
      height: 900,
      notBytes: before.imageBytes,
    );
    expect(rotated.imageWidth, 600);
    expect(rotated.imageHeight, 900);
    await settlePreviewImage(tester);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/photo_cover_crop_rotated_390x844.png'),
    );
  });

  testWidgets('crop preview at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLyberryTheme(),
        home: CoverCropScreen(
          sourceBytes: quadJpeg(width: 900, height: 600),
          transform: transform,
        ),
      ),
    );
    await awaitPreviewStage(tester, width: 900, height: 600);
    await settlePreviewImage(tester);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/photo_cover_crop_320x568_scale1.6.png'),
    );
  });
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// The letterboxed rect an image occupies under `BoxFit.contain`.
Rect _fitRect(Size box, Size image) {
  final scale = (box.width / image.width) < (box.height / image.height)
      ? box.width / image.width
      : box.height / image.height;
  final size = Size(image.width * scale, image.height * scale);
  return Rect.fromLTWH(
    (box.width - size.width) / 2,
    (box.height - size.height) / 2,
    size.width,
    size.height,
  );
}
