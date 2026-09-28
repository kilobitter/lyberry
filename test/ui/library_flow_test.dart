import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:lyberry/services/photo_source.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/screens/cover_crop_screen.dart';
import 'package:lyberry/ui/screens/scan_screen.dart';
import 'package:lyberry/ui/widgets/rating_input.dart';

import '../support/failing_repository.dart';
import '../support/fake_scan_camera.dart';
import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  Future<(LibraryController, InMemoryMediaRepository)> buildController({
    PhotoSource? photoSource,
  }) async {
    final repository = InMemoryMediaRepository();
    final controller = testController(repository, photoSource: photoSource);
    controllers.add(controller);
    await controller.start();
    return (controller, repository);
  }

  Future<void> addCopyThroughEditor(
    WidgetTester tester, {
    String title = 'Dune',
    String creator = 'Frank Herbert',
    String year = '1965',
    String barcode = '9780306406157',
  }) async {
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), title);
    await tester.enterText(find.byKey(const Key('field-creator')), creator);
    await tester.enterText(find.byKey(const Key('field-year')), year);
    await tester.enterText(find.byKey(const Key('field-barcode')), barcode);
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();
  }

  /// Scrolls lazily built form content into view before interacting with it.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      final scrollable = find.byType(Scrollable).first;
      // Return to the top first so the walk down can reach any field.
      await tester.drag(scrollable, const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(finder, 140, scrollable: scrollable);
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('first launch shows the empty state and writes no demo data', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-empty')), findsOneWidget);
    expect(find.text('0 items'), findsWidgets);
    expect(await repository.countItems(), 0);
  });

  testWidgets('adding a copy writes it and shows it in the grid', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await addCopyThroughEditor(tester);

    expect(find.byKey(const Key('home-empty')), findsNothing);
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('1 item'), findsWidgets);

    final stored = (await repository.listItems()).single;
    expect(stored.title, 'Dune');
    expect(stored.creator, 'Frank Herbert');
    expect(stored.year, 1965);
    expect(stored.barcode, '9780306406157');
    expect(stored.medium, MediaType.book);
  });

  testWidgets('editor rejects a bad barcode and shows the field error', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'Dune');
    await tester.enterText(
      find.byKey(const Key('field-barcode')),
      '9780306406158',
    );
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    expect(
      find.text('That barcode or ISBN checksum does not look right.'),
      findsWidgets,
    );
    expect(await repository.countItems(), 0);
  });

  testWidgets('detail shows rating, review and notes and can delete', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'Mezzanine');
    await reveal(tester, find.byKey(const Key('field-review')));
    await tester.enterText(
      find.byKey(const Key('field-review')),
      'Desert island record.',
    );
    await reveal(tester, find.byKey(const Key('field-notes')));
    await tester.enterText(
      find.byKey(const Key('field-notes')),
      'First pressing.',
    );
    await reveal(tester, find.byKey(const Key('rating-4.5')));
    await tester.tap(find.byKey(const Key('rating-4.5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    final id = (await repository.listItems()).single.id;
    await tester.tap(find.byKey(ValueKey<String>(id)));
    await tester.pumpAndSettle();

    expect(find.text('Desert island record.'), findsOneWidget);
    expect(find.text('First pressing.'), findsOneWidget);
    expect(find.text('4.5'), findsOneWidget);

    await tester.tap(find.byKey(const Key('detail-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this copy?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail-delete-confirm')));
    await tester.pumpAndSettle();

    expect(await repository.countItems(), 0);
    expect(find.byKey(const Key('home-empty')), findsOneWidget);
  });

  testWidgets('edit updates the stored copy', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await addCopyThroughEditor(tester);

    final id = (await repository.listItems()).single.id;
    await tester.tap(find.byKey(ValueKey<String>(id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('field-title')),
      'Dune Messiah',
    );
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    final stored = (await repository.listItems()).single;
    expect(stored.title, 'Dune Messiah');
    expect(stored.id, id);
  });

  testWidgets(
    'add another copy clears personal fields and keeps the original',
    (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final (controller, repository) = await buildController();

      await pumpApp(tester, controller);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-add-button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('field-title')), 'Dune');
      await tester.enterText(
        find.byKey(const Key('field-barcode')),
        '9780306406157',
      );
      // The Finished control sits between the rating and the review, so the
      // review field can be below the lazily built viewport.
      await reveal(tester, find.byKey(const Key('field-review')));
      await tester.enterText(
        find.byKey(const Key('field-review')),
        'Loved it.',
      );
      await reveal(tester, find.byKey(const Key('rating-5.0')));
      await tester.tap(find.byKey(const Key('rating-5.0')));
      await tester.pump();
      await reveal(tester, find.byKey(const Key('field-finished')));
      await tester.tap(find.byKey(const Key('field-finished')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('editor-save')));
      await tester.pumpAndSettle();

      final originalId = (await repository.listItems()).single.id;
      await tester.tap(find.byKey(ValueKey<String>(originalId)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('detail-add-copy')));
      await tester.pumpAndSettle();

      final items = await repository.listItems();
      expect(items, hasLength(2));
      final copy = items.firstWhere((item) => item.id != originalId);
      final original = items.firstWhere((item) => item.id == originalId);
      expect(copy.barcode, original.barcode);
      expect(copy.rating, isNull);
      expect(copy.review, isEmpty);
      expect(copy.notes, isEmpty);
      expect(copy.isFinished, isFalse);
      expect(copy.photoAssetIds, isEmpty);
      expect(original.rating, 5.0);
      expect(original.review, 'Loved it.');
      expect(original.isFinished, isTrue);
    },
  );

  testWidgets('search and medium filters narrow the grid', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();

    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Dune',
        creator: 'Frank Herbert',
        createdAt: '2026-09-23T10:00:00.000Z',
        updatedAt: '2026-09-23T10:00:00.000Z',
      ),
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000002',
        medium: MediaType.game,
        title: "Mirror's Edge",
        creator: 'DICE',
        year: 2008,
        createdAt: '2026-09-23T11:00:00.000Z',
        updatedAt: '2026-09-23T11:00:00.000Z',
      ),
    );
    await controller.refresh();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text("Mirror's Edge"), findsOneWidget);

    await tester.enterText(find.byKey(const Key('home-search')), 'mirror');
    await tester.pumpAndSettle();
    expect(find.text("Mirror's Edge"), findsOneWidget);
    expect(find.text('Dune'), findsNothing);

    await tester.enterText(find.byKey(const Key('home-search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-no-results')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-clear-filters')));
    await tester.pumpAndSettle();
    expect(find.text('Dune'), findsOneWidget);

    await tester.tap(find.text('Games'));
    await tester.pumpAndSettle();
    expect(find.text("Mirror's Edge"), findsOneWidget);
    expect(find.text('Dune'), findsNothing);
    expect(find.text('1 item'), findsWidgets);
  });

  testWidgets('cancelled photo picks change nothing and failures are shown', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photoSource = FakePhotoSource();
    final (controller, _) = await buildController(photoSource: photoSource);

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('photo-library')));

    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();
    expect(find.text('0 of 20 photos'), findsOneWidget);
    expect(photoSource.pickCalls, 1);

    photoSource.failure = const PhotoSourceFailure('Camera access is off.');
    await reveal(tester, find.byKey(const Key('photo-camera')));
    await tester.tap(find.byKey(const Key('photo-camera')));
    await tester.pumpAndSettle();
    expect(find.text('Camera access is off.'), findsOneWidget);
    expect(find.text('0 of 20 photos'), findsOneWidget);
  });

  testWidgets('picked photos and a cover are stored with the copy', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photoSource = FakePhotoSource(
      libraryBytes: jpegBytes(width: 40, height: 30),
    );
    final (controller, repository) = await buildController(
      photoSource: photoSource,
    );

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'Dune');
    await reveal(tester, find.byKey(const Key('photo-library')));
    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();
    expect(find.text('1 of 20 photos'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('cover-library')));
    await tester.tap(find.byKey(const Key('cover-library')));
    for (var index = 0; index < 40; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    // A cover picked here goes through the shared crop preview; the derived
    // cover is its own asset and the picked photo is kept on the copy.
    final cropApply = find.byKey(const Key('crop-apply'));
    expect(
      cropApply,
      findsOneWidget,
      reason: 'the cover action opens the crop preview',
    );
    expect(
      tester.widget<FilledButton>(cropApply).onPressed,
      isNotNull,
      reason: 'the crop preview is ready',
    );
    await tester.tap(cropApply);
    for (var index = 0; index < 80; index++) {
      if (find.byType(CoverCropScreen).evaluate().isEmpty) break;
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(CoverCropScreen), findsNothing);

    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    final stored = (await repository.listItems()).single;
    expect(stored.photoAssetIds, hasLength(1));
    expect(stored.coverAssetId, isNotNull);
    expect(stored.coverAssetId, isNot(stored.photoAssetIds.single));
    final asset = await repository.getAsset(stored.photoAssetIds.single);
    expect(asset?.mimeType, AssetMime.jpeg);
    expect(asset?.width, 40);
    final cover = await repository.getAsset(stored.coverAssetId!);
    expect(cover?.mimeType, AssetMime.jpeg);
    expect(cover?.width, 40);
  });

  testWidgets('the editor honours the 20 photo cap', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photoSource = FakePhotoSource(libraryBytes: pngBytes());
    final (controller, repository) = await buildController(
      photoSource: photoSource,
    );
    final assets = <MediaAsset>[
      for (var index = 0; index < 20; index++)
        const ImageIngest().buildAsset(
          pngBytes(red: 10 + index, green: 40 + index, blue: 90 + index),
        ),
    ];
    final full = sampleItem(
      id: '00000000-0000-4000-8000-000000000009',
      title: 'Twenty photos',
      photoAssetIds: <String>[for (final asset in assets) asset.id],
    );
    await repository.createItem(full, assets: assets);
    await controller.refresh();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey<String>(full.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsWidgets, reason: 'editor is open');
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('20 of 20 photos'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('photo-library')));
    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();
    expect(find.text('A copy can hold at most 20 photos.'), findsOneWidget);
    expect(find.text('20 of 20 photos'), findsOneWidget);
  });

  testWidgets(
    'a library that cannot open shows a recoverable error and retries',
    (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));

      final repository = FailingRepository();
      final controller = LibraryController(
        repository: repository,
        clock: FixedClock(kBaseTime),
        idGenerator: SequentialIdGenerator(),
      );
      controllers.add(controller);
      await controller.start();

      await pumpApp(tester, controller);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-error')), findsOneWidget);
      expect(
        find.textContaining('Lyberry could not open your library'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('home-empty')), findsNothing);

      repository.fail = false;
      await tester.tap(find.byKey(const Key('home-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-error')), findsNothing);
      expect(find.byKey(const Key('home-empty')), findsOneWidget);
      expect(repository.initializeCalls, greaterThanOrEqualTo(2));
    },
  );

  testWidgets('a failed save is reported instead of swallowed', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));

    final repository = _WriteFailingRepository();
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'Dune');
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    expect(find.text('Disk is full.'), findsOneWidget);
    // The editor stays open so the user does not lose the entry.
    expect(find.byKey(const Key('field-title')), findsOneWidget);
    expect(await repository.countItems(), 0);
  });

  testWidgets('narrow phone at 1.6x text scale has no overflow', (
    tester,
  ) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'A very long book title that must wrap or ellipsize cleanly',
        creator: 'Somebody With A Remarkably Long Name',
        rating: 3.5,
      ),
    );
    await controller.refresh();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('medium-book')), findsOneWidget);

    await reveal(tester, find.byKey(const Key('field-notes')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail and scan screens fit a narrow large-text phone', (
    tester,
  ) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'A very long book title that must wrap or ellipsize cleanly',
        creator: 'Somebody With A Remarkably Long Name',
        rating: 3.5,
        review: 'A long review that has to wrap across several lines.',
        notes: 'Private note.',
      ),
    );
    await controller.refresh();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(
        const ValueKey<String>('00000000-0000-4000-8000-000000000001'),
      ),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('00000000-0000-4000-8000-000000000001'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();

    // Push the scanner with a stubbed viewfinder: widget tests have no camera.
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ScanScreen(camera: FakeScanCamera()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovered photos are validated, deduped and attached', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photoSource = FakePhotoSource(
      recovered: <PickedPhoto>[
        PickedPhoto(bytes: jpegBytes(width: 20, height: 15)),
        PickedPhoto(bytes: Uint8List.fromList('not an image'.codeUnits)),
      ],
    );
    final (controller, repository) = await buildController(
      photoSource: photoSource,
    );

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    expect(find.textContaining('Recovered 2 photo(s)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('1 recovered photo(s) could not be read'),
      findsOneWidget,
    );

    await reveal(tester, find.text('1 of 20 photos'));
    expect(find.text('1 of 20 photos'), findsOneWidget);

    await reveal(tester, find.byKey(const Key('field-title')));
    await tester.enterText(find.byKey(const Key('field-title')), 'Recovered');
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    final stored = (await repository.listItems()).single;
    expect(stored.photoAssetIds, hasLength(1));
  });

  testWidgets('picking the same photo twice is refused with a notice', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final photoSource = FakePhotoSource(libraryBytes: pngBytes());
    final (controller, _) = await buildController(photoSource: photoSource);

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const Key('photo-library')));

    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-library')));
    await tester.pumpAndSettle();

    expect(find.text('That photo is already on this copy.'), findsOneWidget);
    await reveal(tester, find.text('1 of 20 photos'));
    expect(find.text('1 of 20 photos'), findsOneWidget);
  });

  testWidgets('the photo remove control keeps a 48dp target', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    final photo = const ImageIngest().buildAsset(
      pngBytes(width: 14, height: 14),
    );
    final item = sampleItem(
      id: '00000000-0000-4000-8000-0000000000aa',
      title: 'With a photo',
      photoAssetIds: <String>[photo.id],
    );
    await repository.createItem(item, assets: <MediaAsset>[photo]);
    await controller.refresh();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey<String>(item.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();

    final removeKey = Key('photo-remove-${photo.id}');
    await reveal(tester, find.byKey(removeKey));
    final size = tester.getSize(find.byKey(removeKey));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    await tester.tap(find.byKey(removeKey));
    await tester.pumpAndSettle();
    expect(find.text('No photos yet.'), findsOneWidget);
  });

  testWidgets('rating stars are centred and expose accessible half steps', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, _) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byType(RatingInput));

    final rowLeft = tester.getTopLeft(find.byType(RatingInput)).dx;
    final firstStarCenter = tester
        .getCenter(find.byIcon(Icons.star_border).first)
        .dx;
    expect(firstStarCenter - rowLeft, closeTo(24, 1.5));
    expect(find.byIcon(Icons.star_border), findsNWidgets(5));

    await tester.tap(find.byKey(const Key('rating-3.5')));
    await tester.pump();
    expect(find.text('3.5'), findsOneWidget);

    await tester.tap(find.byKey(const Key('rating-4.0')));
    await tester.pump();
    expect(find.text('4.0'), findsOneWidget);

    final handle = tester.ensureSemantics();
    final data = tester
        .getSemantics(find.byType(RatingInput))
        .getSemanticsData();
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    expect(data.increasedValue, '4.5');
    expect(data.decreasedValue, '3.5');
    handle.dispose();
  });

  testWidgets('a delayed save does not pop a route the user navigated to', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final repository = _DelayedWriteRepository();
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'Slow copy');
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pump();

    // The user leaves while the write is still in flight.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('field-title')), findsNothing);
    expect(find.byKey(const Key('home-search')), findsOneWidget);

    repository.gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('home-search')), findsOneWidget);
    expect(find.byKey(const Key('home-empty')), findsNothing);
    expect((await repository.listItems()).single.title, 'Slow copy');
  });

  testWidgets('a rated editor fits a narrow large-text phone', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final (controller, _) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byType(RatingInput));

    // Rating turns on the value text and the clear action, which is where the
    // row used to exceed the 280 px content width.
    await tester.tap(find.byKey(const Key('rating-4.0')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('4.0'), findsOneWidget);

    // Half-star choices and the clear action stay reachable after rating.
    await tester.tap(find.byKey(const Key('rating-2.5')));
    await tester.pumpAndSettle();
    expect(find.text('2.5'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final clear = find.byTooltip('Clear rating');
    expect(clear, findsOneWidget);
    expect(tester.getSize(clear).width, greaterThanOrEqualTo(48));
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('Unrated'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// In-memory store whose writes always fail, to check error surfacing.
class _WriteFailingRepository extends InMemoryMediaRepository {
  @override
  Future<void> createItem(
    MediaItem item, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async {
    throw const StorageFailure('Disk is full.');
  }
}

/// In-memory store whose write waits for the test to release it.
class _DelayedWriteRepository extends InMemoryMediaRepository {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> createItem(
    MediaItem item, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async {
    await gate.future;
    return super.createItem(item, assets: assets);
  }
}
