import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/widgets/rating_input.dart';

import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

// Renders the real widgets at phone size and writes PNG evidence.
// Run with: flutter test --update-goldens test/golden
// The PNGs are copied into docs/agent-work/lyberry/evidence/p1/.
void main() {
  setUpAll(loadAppFonts);

  Future<LibraryController> seededLibrary({bool duneFinished = false}) async {
    final repository = InMemoryMediaRepository();
    final ingest = const ImageIngest();
    final duneCover = ingest.buildAsset(
      posterBytes(
        title: 'DUNE',
        caption: 'FRANK HERBERT',
        red: 196,
        green: 96,
        blue: 52,
      ),
    );
    final mezzanineCover = ingest.buildAsset(
      posterBytes(
        title: 'MEZZANINE',
        caption: 'MASSIVE ATTACK',
        red: 28,
        green: 30,
        blue: 32,
      ),
    );
    final bladeCover = ingest.buildAsset(
      posterBytes(
        title: 'BLADE RUNNER',
        caption: '2049',
        red: 22,
        green: 42,
        blue: 74,
      ),
    );
    final mirrorCover = ingest.buildAsset(
      posterBytes(
        title: 'MIRRORS EDGE',
        caption: 'DICE',
        red: 214,
        green: 216,
        blue: 214,
      ),
    );
    final shelfPhoto = ingest.buildAsset(
      posterBytes(
        title: 'SHELF',
        caption: 'PHOTO',
        red: 44,
        green: 48,
        blue: 52,
        width: 480,
        height: 640,
      ),
    );

    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Dune',
        creator: 'Frank Herbert',
        publisher: 'Chilton',
        year: 1965,
        barcode: '9780306406157',
        rating: 4.5,
        review: 'Still the most complete piece of world building I own.',
        notes: 'Signed second printing.',
        isFinished: duneFinished,
        coverAssetId: duneCover.id,
        photoAssetIds: <String>[shelfPhoto.id],
        createdAt: '2026-09-23T10:00:00.000Z',
        updatedAt: '2026-09-23T10:00:00.000Z',
      ),
      assets: <MediaAsset>[duneCover, shelfPhoto],
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000002',
        medium: MediaType.vinyl,
        title: 'Mezzanine',
        creator: 'Massive Attack',
        publisher: 'Virgin',
        year: 1998,
        barcode: '0724384654726',
        rating: 5.0,
        coverAssetId: mezzanineCover.id,
        createdAt: '2026-09-23T11:00:00.000Z',
        updatedAt: '2026-09-23T11:00:00.000Z',
      ),
      assets: <MediaAsset>[mezzanineCover],
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000003',
        medium: MediaType.bluray,
        title: 'Blade Runner 2049',
        creator: 'Denis Villeneuve',
        publisher: 'Warner Bros.',
        year: 2017,
        barcode: '5051892202657',
        rating: 4.5,
        coverAssetId: bladeCover.id,
        createdAt: '2026-09-23T12:00:00.000Z',
        updatedAt: '2026-09-23T12:00:00.000Z',
      ),
      assets: <MediaAsset>[bladeCover],
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000004',
        medium: MediaType.game,
        title: "Mirror's Edge",
        creator: 'DICE',
        publisher: 'Electronic Arts',
        platform: 'PlayStation 3',
        year: 2008,
        rating: 5.0,
        coverAssetId: mirrorCover.id,
        createdAt: '2026-09-23T13:00:00.000Z',
        updatedAt: '2026-09-23T13:00:00.000Z',
      ),
      assets: <MediaAsset>[mirrorCover],
    );

    final controller = testController(repository);
    await controller.start();
    return controller;
  }

  Future<void> settleImages(
    WidgetTester tester,
    LibraryController controller,
  ) async {
    await tester.runAsync(() async {
      final ids = <String>[
        for (final item in controller.items) ...<String>[
          if (item.coverAssetId != null) item.coverAssetId!,
          ...item.photoAssetIds,
        ],
      ];
      for (final id in ids) {
        await controller.asset(id);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    for (var index = 0; index < 4; index++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('home grid at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final controller = await seededLibrary();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await settleImages(tester, controller);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_390x844.png'),
    );
  });

  testWidgets('detail view at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final controller = await seededLibrary();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('00000000-0000-4000-8000-000000000001'),
      ),
    );
    await tester.pumpAndSettle();
    await settleImages(tester, controller);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/detail_390x844.png'),
    );
  });

  testWidgets('editor at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final controller = await seededLibrary();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'New arrival');
    await tester.pumpAndSettle();
    await settleImages(tester, controller);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/editor_390x844.png'),
    );
  });

  testWidgets('finished book detail at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final controller = await seededLibrary(duneFinished: true);

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('00000000-0000-4000-8000-000000000001'),
      ),
    );
    await tester.pumpAndSettle();
    await settleImages(tester, controller);
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/detail_finished_390x844.png'),
    );
  });

  testWidgets('finished book editor at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final controller = await seededLibrary(duneFinished: true);

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('00000000-0000-4000-8000-000000000001'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('field-finished')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/editor_finished_390x844.png'),
    );
  });

  testWidgets('home grid at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final controller = await seededLibrary();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await settleImages(tester, controller);

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/home_320x568_scale1.6.png'),
    );
  });

  testWidgets('rated editor at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final controller = await seededLibrary();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();

    final rating = find.byType(RatingInput);
    await tester.scrollUntilVisible(
      rating,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rating-4.0')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/editor_320x568_rated_scale1.6.png'),
    );
  });
}
