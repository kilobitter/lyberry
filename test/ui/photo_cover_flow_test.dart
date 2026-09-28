import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/cover_renderer.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/cover_downloader.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:lyberry/services/image_transform.dart';
import 'package:lyberry/services/photo_source.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/library_scope.dart';
import 'package:lyberry/ui/screens/cover_crop_screen.dart';
import 'package:lyberry/ui/screens/editor_screen.dart';

import '../support/fake_transport.dart';
import '../support/in_memory_repository.dart';
import '../support/photo_fixtures.dart';
import '../support/test_support.dart';

const String kItemId = '00000000-0000-4000-8000-000000000001';
const String kCoverUrl = 'https://covers.openlibrary.org/b/id/42-L.jpg';

const ImageTransformService kTransform = ImageTransformService(
  worker: InlineImageRenderWorker(),
);

void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  MediaAsset asset(Uint8List bytes) => const ImageIngest().buildAsset(bytes);

  /// Advances fake time in fixed steps; used where a spinner may be on screen,
  /// because `pumpAndSettle` would never return with an animation running.
  Future<void> pumpFrames(WidgetTester tester, {int frames = 6}) async {
    for (var index = 0; index < frames; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Waits for the crop preview to finish loading and enable Apply.
  Future<void> pumpCropReady(WidgetTester tester, {int frames = 150}) async {
    for (var index = 0; index < frames; index++) {
      final apply = find.byKey(CoverCropScreen.applyKey);
      if (apply.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(apply).onPressed != null) {
        // The preview is ready, so no spinner is left: finish the page
        // transition before the test taps anything.
        await tester.pumpAndSettle();
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Waits for the crop route to actually leave the tree, however long the
  /// platform's page transition is.
  Future<void> pumpCropClosed(WidgetTester tester, {int frames = 250}) async {
    for (var index = 0; index < frames; index++) {
      if (find.byType(CoverCropScreen).evaluate().isEmpty) return;
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// Settles the tree deterministically. `pumpAndSettle` cannot be used while
  /// the crop screen is on stage (its transform spinner never settles), so that
  /// case waits for the preview instead; [frames] forces a bounded pump.
  Future<void> settle(WidgetTester tester, {int frames = 0}) async {
    if (frames > 0) {
      await pumpFrames(tester, frames: frames);
      return;
    }
    if (find.byType(CoverCropScreen).evaluate().isNotEmpty) {
      await pumpCropReady(tester);
      return;
    }
    // Flush one frame first: a pending crop push lands here, and a spinner on
    // screen would make pumpAndSettle hang.
    await tester.pump();
    if (find.byType(CoverCropScreen).evaluate().isNotEmpty) {
      await pumpCropReady(tester);
      return;
    }
    await tester.pumpAndSettle();
  }

  /// The editor's own list, not the hidden Scrollable inside a text field.
  Finder editorScrollable() => find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;

  /// Scrolls lazily built form content into view before interacting with it.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      return;
    }
    final scrollable = editorScrollable();
    final state = tester.state<ScrollableState>(scrollable);
    if (state.position.pixels != 0) {
      // Start from the top so the walk down reaches any field.
      state.position.jumpTo(0);
      await tester.pumpAndSettle();
    }
    await tester.scrollUntilVisible(finder, 140, scrollable: scrollable);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<(LibraryController, InMemoryMediaRepository)> buildLibrary({
    List<MediaAsset> assets = const <MediaAsset>[],
    List<String> photoIds = const <String>[],
    String? coverAssetId,
    PhotoSource? photoSource,
  }) async {
    final repository = InMemoryMediaRepository();
    await repository.createItem(
      sampleItem(
        id: kItemId,
        title: 'Dune',
        medium: MediaType.book,
        coverAssetId: coverAssetId,
        photoAssetIds: photoIds,
      ),
      assets: assets,
    );
    final controller = testController(repository, photoSource: photoSource);
    controllers.add(controller);
    await controller.start();
    return (controller, repository);
  }

  Future<void> openEditor(
    WidgetTester tester,
    LibraryController controller, {
    AppServices? services,
  }) async {
    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>(kItemId)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
  }

  /// Taps Apply and waits for the crop route to actually close, reporting the
  /// on-screen error if it does not.
  Future<void> applyCrop(WidgetTester tester) async {
    final apply = find.byKey(CoverCropScreen.applyKey);
    expect(apply, findsOneWidget, reason: 'the crop preview is open');
    await pumpCropReady(tester);
    expect(
      tester.widget<FilledButton>(apply).onPressed,
      isNotNull,
      reason: 'Apply is enabled once the preview is ready',
    );
    expect(
      find.byKey(const Key('crop-error')),
      findsNothing,
      reason: 'the preview loaded',
    );
    await tester.tap(apply);
    await pumpCropClosed(tester);
    if (find.byType(CoverCropScreen).evaluate().isNotEmpty) {
      final error = find.byKey(const Key('crop-error'));
      final shown = error.evaluate().isEmpty
          ? '<no error shown>'
          : tester.widget<Text>(error).data;
      fail('the crop route never closed after Apply; screen shows: $shown');
    }
    await tester.pumpAndSettle();
  }

  /// Saves and proves the write actually ran: a missed hit test would leave the
  /// editor open with no confirmation.
  Future<void> saveEditor(WidgetTester tester) async {
    expect(
      find.byType(CoverCropScreen),
      findsNothing,
      reason: 'no crop route is covering the editor',
    );
    final save = find.byKey(const Key('editor-save-bottom'));
    expect(save, findsOneWidget);
    expect(
      tester.widget<FilledButton>(save).onPressed,
      isNotNull,
      reason: 'Save is enabled',
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Copy updated.'), findsOneWidget, reason: 'Save executed');
  }

  /// Hosts the editor the way the app does: pushed over a persistent Scaffold
  /// route, so Save pops back onto a route that can show the confirmation.
  Future<void> pumpHostedEditor(
    WidgetTester tester, {
    required LibraryController controller,
    required AppServices services,
    required MediaItem item,
    String? coverUrl,
  }) async {
    await tester.pumpWidget(
      LibraryScope(
        controller: controller,
        child: AppServicesScope(
          services: services,
          child: MaterialApp(
            home: Scaffold(
              key: const Key('host-route'),
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    key: const Key('host-open-editor'),
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            EditorScreen(existing: item, coverUrl: coverUrl),
                      ),
                    ),
                    child: const Text('Open editor'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-open-editor')));
    await tester.pumpAndSettle();
  }

  /// Drags the bottom-right crop handle inward by [delta].
  Future<void> dragCropCorner(
    WidgetTester tester,
    Offset delta, {
    Size image = const Size(240, 120),
  }) async {
    final stage = tester.getRect(find.byKey(CoverCropScreen.stageKey));
    final fitted = _fitRect(stage.size, image);
    final corner =
        stage.topLeft +
        Offset(fitted.right, fitted.bottom) -
        const Offset(6, 6);
    await tester.dragFrom(corner, delta);
    await pumpFrames(tester, frames: 4);
  }

  MediaAsset derivedFrom(Uint8List source) =>
      CoverRenderer.deriveCoverAsset(source: source, crop: CoverCrop.full);

  testWidgets(
    'a stored photo becomes the cover and the original is untouched',
    (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final photo = asset(quadJpeg());
      final (controller, repository) = await buildLibrary(
        assets: <MediaAsset>[photo],
        photoIds: <String>[photo.id],
      );

      await openEditor(tester, controller);
      await reveal(tester, find.byKey(Key('photo-cover-${photo.id}')));
      await tester.tap(find.byKey(Key('photo-cover-${photo.id}')));
      await settle(tester);

      await dragCropCorner(tester, const Offset(-70, -40));
      await applyCrop(tester);
      await saveEditor(tester);

      final stored = (await repository.getItem(kItemId))!;
      expect(stored.photoAssetIds, <String>[photo.id]);
      expect(stored.coverAssetId, isNotNull);
      expect(stored.coverAssetId, isNot(photo.id));

      final cover = (await repository.getAsset(stored.coverAssetId!))!;
      final coverPixels = decodeBytes(cover.bytes);
      expect(cover.mimeType, AssetMime.jpeg);
      expect(
        coverPixels.width,
        lessThan(240),
        reason: 'the drag narrowed the saved pixels',
      );
      expect(coverPixels.height, lessThan(120));
      expect(
        cover.id,
        isNot(derivedFrom(photo.bytes).id),
        reason: 'the saved cover is not the uncropped frame',
      );

      final unchanged = (await repository.getAsset(photo.id))!;
      expect(unchanged.bytes, orderedEquals(photo.bytes));
    },
  );

  testWidgets('a photo picked for the cover is kept as a personal photo', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final picked = quadJpeg(width: 320, height: 160);
    final source = FakePhotoSource(libraryBytes: picked);
    final (controller, repository) = await buildLibrary(photoSource: source);

    await openEditor(tester, controller);
    await reveal(tester, find.byKey(const Key('cover-library')));
    await tester.tap(find.byKey(const Key('cover-library')));
    await settle(tester);

    await applyCrop(tester);
    await saveEditor(tester);

    final stored = (await repository.getItem(kItemId))!;
    expect(source.pickCalls, 1);
    expect(stored.photoAssetIds, <String>[MediaAsset.fromBytes(picked).id]);
    final kept = (await repository.getAsset(stored.photoAssetIds.single))!;
    expect(decodeBytes(kept.bytes).width, 320);
    expect(stored.coverAssetId, derivedFrom(picked).id);
    expect(stored.coverAssetId, isNot(kept.id));
  });

  testWidgets('cancelling the crop keeps the previous cover', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photo = asset(quadJpeg());
    final existingCover = asset(quadJpeg(width: 100, height: 200));
    final (controller, repository) = await buildLibrary(
      assets: <MediaAsset>[photo, existingCover],
      photoIds: <String>[photo.id],
      coverAssetId: existingCover.id,
    );

    await openEditor(tester, controller);
    await reveal(tester, find.byKey(Key('photo-cover-${photo.id}')));
    await tester.tap(find.byKey(Key('photo-cover-${photo.id}')));
    await settle(tester);
    await tester.tap(find.byKey(CoverCropScreen.cancelKey));
    await pumpCropClosed(tester);
    await tester.pumpAndSettle();
    expect(find.byType(CoverCropScreen), findsNothing);

    await saveEditor(tester);
    final stored = (await repository.getItem(kItemId))!;
    expect(stored.coverAssetId, existingCover.id);
  });

  testWidgets('removing the photo keeps the derived cover', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photo = asset(quadJpeg());
    final derived = MediaAsset.fromBytes(
      CoverRenderer.renderCover(
        source: photo.bytes,
        crop: const CoverCrop(left: 0, top: 0, width: 0.6, height: 0.6),
      ),
    );
    final (controller, repository) = await buildLibrary(
      assets: <MediaAsset>[photo, derived],
      photoIds: <String>[photo.id],
      coverAssetId: derived.id,
    );

    await openEditor(tester, controller);
    await reveal(tester, find.byKey(Key('photo-remove-${photo.id}')));
    await tester.tap(find.byKey(Key('photo-remove-${photo.id}')));
    await settle(tester, frames: 4);
    await saveEditor(tester);

    final stored = (await repository.getItem(kItemId))!;
    expect(stored.photoAssetIds, isEmpty);
    expect(stored.coverAssetId, derived.id);
    expect(await repository.getAsset(derived.id), isNotNull);
  });

  testWidgets('removing the cover keeps the photos', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photo = asset(quadJpeg());
    final derived = MediaAsset.fromBytes(
      CoverRenderer.renderCover(
        source: photo.bytes,
        crop: const CoverCrop(left: 0.2, top: 0.2, width: 0.5, height: 0.5),
      ),
    );
    final (controller, repository) = await buildLibrary(
      assets: <MediaAsset>[photo, derived],
      photoIds: <String>[photo.id],
      coverAssetId: derived.id,
    );

    await openEditor(tester, controller);
    await reveal(tester, find.byKey(const Key('cover-remove')));
    await tester.tap(find.byKey(const Key('cover-remove')));
    await settle(tester, frames: 4);
    await saveEditor(tester);

    final stored = (await repository.getItem(kItemId))!;
    expect(stored.coverAssetId, isNull);
    expect(stored.photoAssetIds, <String>[photo.id]);
  });

  testWidgets('the cover action keeps a real 48dp touch target', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photo = asset(quadJpeg());
    final (controller, _) = await buildLibrary(
      assets: <MediaAsset>[photo],
      photoIds: <String>[photo.id],
    );

    await openEditor(tester, controller);
    final action = find.byKey(Key('photo-cover-${photo.id}'));
    await reveal(tester, action);
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
  });

  testWidgets(
    'a full photo list explains before capture and offers the photos',
    (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final photos = <MediaAsset>[
        for (var index = 0; index < 20; index++)
          asset(pngBytes(red: 20 + index * 5, green: 90, blue: 120)),
      ];
      final source = FakePhotoSource(cameraBytes: quadJpeg());
      final (controller, _) = await buildLibrary(
        assets: photos,
        photoIds: photos.map((photo) => photo.id).toList(),
        photoSource: source,
      );

      await openEditor(tester, controller);
      await reveal(tester, find.byKey(const Key('cover-camera')));
      await tester.tap(find.byKey(const Key('cover-camera')));
      await settle(tester);

      expect(find.text('All 20 photos are used'), findsOneWidget);
      expect(source.cameraCalls, 0);

      await tester.tap(find.byKey(const Key('cover-limit-existing')));
      await settle(tester);
      expect(find.text('Choose a photo'), findsOneWidget);

      await tester.tap(find.byKey(Key('cover-existing-${photos.first.id}')));
      await settle(tester);
      expect(find.byKey(CoverCropScreen.applyKey), findsOneWidget);
    },
  );

  testWidgets('a manual cover choice beats a late provider download', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photo = asset(quadJpeg());
    final (controller, repository) = await buildLibrary(
      assets: <MediaAsset>[photo],
      photoIds: <String>[photo.id],
    );

    final transport = FakeHttpTransport();
    final downloadedBytes = quadJpeg(width: 80, height: 40);
    transport.answerBytes(
      kCoverUrl,
      downloadedBytes,
      delay: const Duration(seconds: 2),
    );
    final services = testServices(
      repository: repository,
      covers: CoverDownloader(transport: transport),
      images: kTransform,
    );
    final item = (await repository.getItem(kItemId))!;
    await pumpHostedEditor(
      tester,
      controller: controller,
      services: services,
      item: item,
      coverUrl: kCoverUrl,
    );

    await reveal(tester, find.byKey(Key('photo-cover-${photo.id}')));
    await tester.tap(find.byKey(Key('photo-cover-${photo.id}')));
    await settle(tester);
    await applyCrop(tester);

    // The provider cover finally lands after the manual choice.
    await tester.pump(const Duration(seconds: 3));
    await settle(tester, frames: 4);
    await saveEditor(tester);

    final stored = (await repository.getItem(kItemId))!;
    expect(transport.requests, hasLength(1), reason: 'the download ran');
    expect(stored.coverAssetId, isNotNull);
    expect(
      stored.coverAssetId,
      derivedFrom(photo.bytes).id,
      reason: 'the manual full-frame cover is stored',
    );
    expect(
      stored.coverAssetId,
      isNot(MediaAsset.fromBytes(downloadedBytes).id),
      reason: 'the late download must not replace the manual cover',
    );
    expect(stored.photoAssetIds, <String>[photo.id]);
  });

  testWidgets('manual intent wins while the source bytes are still loading', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final picked = quadJpeg(width: 200, height: 100);
    final source = _DeferredPhotoSource(picked);
    final (controller, repository) = await buildLibrary(photoSource: source);

    final transport = FakeHttpTransport();
    final downloadedBytes = quadJpeg(width: 60, height: 30);
    transport.answerBytes(
      kCoverUrl,
      downloadedBytes,
      delay: const Duration(seconds: 2),
    );
    final services = testServices(
      repository: repository,
      covers: CoverDownloader(transport: transport),
      images: kTransform,
      photoSource: source,
    );
    final item = (await repository.getItem(kItemId))!;
    await pumpHostedEditor(
      tester,
      controller: controller,
      services: services,
      item: item,
      coverUrl: kCoverUrl,
    );

    await reveal(tester, find.byKey(const Key('cover-library')));
    await tester.tap(find.byKey(const Key('cover-library')));
    await tester.pump();
    expect(source.pickCalls, 1);

    // The provider cover lands while the picker is still open.
    await tester.pump(const Duration(seconds: 3));
    expect(transport.requests, hasLength(1), reason: 'the download ran');

    source.gate.complete();
    await settle(tester);
    await applyCrop(tester);
    await saveEditor(tester);

    final stored = (await repository.getItem(kItemId))!;
    expect(
      stored.coverAssetId,
      derivedFrom(picked).id,
      reason: 'the manual crop is the cover',
    );
    expect(
      stored.coverAssetId,
      isNot(MediaAsset.fromBytes(downloadedBytes).id),
    );
    expect(stored.photoAssetIds, <String>[MediaAsset.fromBytes(picked).id]);
  });

  testWidgets('a capture in flight blocks a second action and the save', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final picked = quadJpeg(width: 200, height: 100);
    final source = _DeferredPhotoSource(picked);
    final (controller, repository) = await buildLibrary(photoSource: source);

    await openEditor(tester, controller);
    await reveal(tester, find.byKey(const Key('photo-library')));
    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pump();
    expect(source.pickCalls, 1);

    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('photo-library')))
          .onPressed,
      isNull,
      reason: 'the photo action is disabled while a capture is open',
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('editor-save-bottom')))
          .onPressed,
      isNull,
      reason: 'Save is disabled while a capture is open',
    );
    await tester.tap(
      find.byKey(const Key('photo-library')),
      warnIfMissed: false,
    );
    await tester.tap(
      find.byKey(const Key('editor-save-bottom')),
      warnIfMissed: false,
    );
    await settle(tester, frames: 4);
    expect(
      source.pickCalls,
      1,
      reason: 'the second tap never reached the picker',
    );
    expect(find.text('Copy updated.'), findsNothing, reason: 'Save never ran');
    expect(
      (await repository.getItem(kItemId))!.photoAssetIds,
      isEmpty,
      reason: 'a draft without Save writes nothing',
    );

    source.gate.complete();
    await settle(tester);
    await saveEditor(tester);
    final stored = (await repository.getItem(kItemId))!;
    expect(stored.photoAssetIds.length, 1);
    expect(stored.photoAssetIds.single, MediaAsset.fromBytes(picked).id);
  });

  testWidgets(
    'a source load that outlives the editor never pushes the crop screen',
    (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final source = _DeferredPhotoSource(quadJpeg(width: 200, height: 100));
      final (controller, repository) = await buildLibrary(photoSource: source);

      await openEditor(tester, controller);
      await reveal(tester, find.byKey(const Key('cover-library')));
      await tester.tap(find.byKey(const Key('cover-library')));
      await tester.pump();
      expect(source.pickCalls, 1);

      // Leave the editor while the picker is still open.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('detail-edit')),
        findsOneWidget,
        reason: 'back on the detail route',
      );

      source.gate.complete();
      await tester.pumpAndSettle();

      expect(
        find.byType(CoverCropScreen),
        findsNothing,
        reason: 'the deferred source must not open the crop screen here',
      );
      expect(find.byType(EditorScreen), findsNothing);
      expect(find.byKey(const Key('detail-edit')), findsOneWidget);
      final stored = (await repository.getItem(kItemId))!;
      expect(stored.coverAssetId, isNull);
      expect(stored.photoAssetIds, isEmpty);
    },
  );

  testWidgets(
    'a source removed from the draft is kept again when picked for the cover',
    (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final picked = quadJpeg(width: 200, height: 100);
      final source = FakePhotoSource(libraryBytes: picked);
      final (controller, repository) = await buildLibrary(photoSource: source);
      final pickedAsset = MediaAsset.fromBytes(picked);

      await openEditor(tester, controller);
      await reveal(tester, find.byKey(const Key('photo-library')));
      await tester.tap(find.byKey(const Key('photo-library')));
      await settle(tester);
      expect(find.byKey(Key('photo-remove-${pickedAsset.id}')), findsOneWidget);

      await tester.tap(find.byKey(Key('photo-remove-${pickedAsset.id}')));
      await settle(tester, frames: 4);
      expect(find.byKey(Key('photo-remove-${pickedAsset.id}')), findsNothing);

      await reveal(tester, find.byKey(const Key('cover-library')));
      await tester.tap(find.byKey(const Key('cover-library')));
      await settle(tester);
      await applyCrop(tester);
      await saveEditor(tester);

      final stored = (await repository.getItem(kItemId))!;
      expect(stored.photoAssetIds, <String>[
        pickedAsset.id,
      ], reason: 'the original comes back with its cover');
      expect(stored.coverAssetId, derivedFrom(picked).id);
      expect(stored.coverAssetId, isNot(pickedAsset.id));
    },
  );

  testWidgets('cancelling the editor after a crop persists nothing', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photo = asset(quadJpeg());
    final (controller, repository) = await buildLibrary(
      assets: <MediaAsset>[photo],
      photoIds: <String>[photo.id],
    );

    await openEditor(tester, controller);
    await reveal(tester, find.byKey(Key('photo-cover-${photo.id}')));
    await tester.tap(find.byKey(Key('photo-cover-${photo.id}')));
    await settle(tester);
    await applyCrop(tester);

    await tester.pageBack();
    await settle(tester);

    expect(find.text('Copy updated.'), findsNothing, reason: 'no save ran');
    final stored = (await repository.getItem(kItemId))!;
    expect(stored.coverAssetId, isNull);
    expect(stored.photoAssetIds, <String>[photo.id]);
    final snapshot = await repository.exportSnapshot();
    expect(
      snapshot.assets.length,
      1,
      reason: 'the abandoned derived cover was never written',
    );
  });

  testWidgets('the crop preview shows a stable error with retry and cancel', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await tester.pumpWidget(
      MaterialApp(
        home: CoverCropScreen(
          sourceBytes: Uint8List.fromList(List<int>.filled(96, 3)),
          transform: kTransform,
        ),
      ),
    );
    await settle(tester);

    expect(find.byKey(const Key('crop-error')), findsOneWidget);
    expect(find.textContaining('JPEG, PNG or WebP'), findsOneWidget);
    expect(find.byKey(const Key('crop-error-retry')), findsOneWidget);
    expect(find.byKey(const Key('crop-error-cancel')), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'a failed load is a stable state, not a spinner',
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(CoverCropScreen.applyKey))
          .onPressed,
      isNull,
    );

    // Retrying the same unreadable bytes keeps the stable error.
    await tester.tap(find.byKey(const Key('crop-error-retry')));
    await settle(tester);
    expect(find.byKey(const Key('crop-error')), findsOneWidget);
  });

  testWidgets('a failed apply keeps the old cover and can be retried', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final worker = _FlakyRenderWorker();
    MediaAsset? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const Key('open-crop'),
                onPressed: () async {
                  popped = await Navigator.of(context).push<MediaAsset>(
                    MaterialPageRoute<MediaAsset>(
                      builder: (_) => CoverCropScreen(
                        sourceBytes: quadJpeg(),
                        transform: ImageTransformService(worker: worker),
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const Key('open-crop')));
    await settle(tester);

    await tester.tap(find.byKey(CoverCropScreen.applyKey));
    await settle(tester);
    expect(worker.renderCalls, 1);
    expect(find.byType(CoverCropScreen), findsOneWidget);
    expect(find.byKey(const Key('crop-error')), findsOneWidget);
    expect(popped, isNull, reason: 'nothing was returned');

    // The retry uses the untouched original and succeeds.
    await tester.tap(find.byKey(CoverCropScreen.applyKey));
    await pumpCropClosed(tester);
    await tester.pumpAndSettle();
    expect(popped, isNotNull, reason: 'the retried render returned a cover');
    expect(find.byType(CoverCropScreen), findsNothing);
  });

  testWidgets(
    'a render finishing during the back transition never pops the editor',
    (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final worker = _GatedRenderWorker();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            key: const Key('host-route'),
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  key: const Key('host-open'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => CoverCropScreen(
                        sourceBytes: quadJpeg(),
                        transform: ImageTransformService(worker: worker),
                      ),
                    ),
                  ),
                  child: const Text('Open crop'),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('host-open')));
      await settle(tester);
      expect(find.byType(CoverCropScreen), findsOneWidget);

      await tester.tap(find.byKey(CoverCropScreen.applyKey));
      await tester.pump();
      expect(worker.renderCalls, 1);

      // Leave while the render is still in flight.
      await tester.tap(find.byKey(CoverCropScreen.cancelKey));
      await tester.pump(const Duration(milliseconds: 40));

      // The render now finishes; it must not pop the route underneath.
      worker.gate.complete();
      await pumpCropClosed(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('host-route')), findsOneWidget);
      expect(find.text('Open crop'), findsOneWidget);
      expect(find.byType(CoverCropScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the crop preview stays usable at 320px with 1.6x text', (
    tester,
  ) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    await tester.pumpWidget(
      MaterialApp(
        home: CoverCropScreen(sourceBytes: quadJpeg(), transform: kTransform),
      ),
    );
    await settle(tester);

    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(CoverCropScreen.rotateRightKey));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(CoverCropScreen.rotateLeftKey));
    await settle(tester);
    await tester.tap(find.byKey(CoverCropScreen.resetKey));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(CoverCropScreen.applyKey))
          .onPressed,
      isNotNull,
    );
  });
}

/// A photo source whose pick waits for the test to release it.
class _DeferredPhotoSource implements PhotoSource {
  _DeferredPhotoSource(this.bytes);

  final Uint8List bytes;
  final Completer<void> gate = Completer<void>();
  int pickCalls = 0;
  int cameraCalls = 0;

  @override
  Future<PickedPhoto?> pick() async {
    pickCalls++;
    await gate.future;
    return PickedPhoto(bytes: bytes, sourceName: 'deferred.jpg');
  }

  @override
  Future<PickedPhoto?> capture() async {
    cameraCalls++;
    await gate.future;
    return PickedPhoto(bytes: bytes, sourceName: 'deferred-camera.jpg');
  }

  @override
  Future<List<PickedPhoto>> recoverLostPhotos() async => const <PickedPhoto>[];
}

/// The real inline pipeline, held back until the test releases it.
class _GatedRenderWorker implements ImageRenderWorker {
  static const ImageRenderWorker _inner = InlineImageRenderWorker();

  final Completer<void> gate = Completer<void>();
  int renderCalls = 0;

  @override
  Future<CoverPreview> preparePreview({
    required Uint8List source,
    required ImageLimits limits,
    required int maxDimension,
  }) => _inner.preparePreview(
    source: source,
    limits: limits,
    maxDimension: maxDimension,
  );

  @override
  Future<CoverPreview> rotatePreview({
    required Uint8List preview,
    required int quarterTurns,
  }) => _inner.rotatePreview(preview: preview, quarterTurns: quarterTurns);

  @override
  Future<MediaAsset> renderCover({
    required Uint8List source,
    required CoverCrop crop,
    required ImageLimits limits,
    required int maxDimension,
    required int jpegQuality,
    required String field,
  }) async {
    renderCalls++;
    await gate.future;
    return _inner.renderCover(
      source: source,
      crop: crop,
      limits: limits,
      maxDimension: maxDimension,
      jpegQuality: jpegQuality,
      field: field,
    );
  }
}

/// Fails the first render the way a bad source would, then succeeds.
class _FlakyRenderWorker implements ImageRenderWorker {
  static const ImageRenderWorker _inner = InlineImageRenderWorker();

  int renderCalls = 0;

  @override
  Future<CoverPreview> preparePreview({
    required Uint8List source,
    required ImageLimits limits,
    required int maxDimension,
  }) => _inner.preparePreview(
    source: source,
    limits: limits,
    maxDimension: maxDimension,
  );

  @override
  Future<CoverPreview> rotatePreview({
    required Uint8List preview,
    required int quarterTurns,
  }) => _inner.rotatePreview(preview: preview, quarterTurns: quarterTurns);

  @override
  Future<MediaAsset> renderCover({
    required Uint8List source,
    required CoverCrop crop,
    required ImageLimits limits,
    required int maxDimension,
    required int jpegQuality,
    required String field,
  }) async {
    renderCalls++;
    if (renderCalls == 1) {
      throw const ValidationException([
        ValidationIssue('cover', 'That photo could not be prepared.'),
      ]);
    }
    return _inner.renderCover(
      source: source,
      crop: crop,
      limits: limits,
      maxDimension: maxDimension,
      jpegQuality: jpegQuality,
      field: field,
    );
  }
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
