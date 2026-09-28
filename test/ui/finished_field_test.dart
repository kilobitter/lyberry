import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/state/library_controller.dart';

import '../support/in_memory_repository.dart';
import '../support/stub_provider.dart';
import '../support/test_support.dart';

const String kItemId = '00000000-0000-4000-8000-000000000001';
const Key kFinished = Key('field-finished');

void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  Future<(LibraryController, InMemoryMediaRepository)> buildLibrary({
    bool seedFinishedBook = false,
  }) async {
    final repository = InMemoryMediaRepository();
    if (seedFinishedBook) {
      await repository.createItem(
        sampleItem(
          id: kItemId,
          medium: MediaType.book,
          title: 'Dune',
          isFinished: true,
        ),
      );
    }
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    return (controller, repository);
  }

  /// Scrolls until [finder] is on screen; a negative [delta] scrolls backwards.
  Future<void> show(
    WidgetTester tester,
    Finder finder, {
    double delta = 160,
  }) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        delta,
        scrollable: find.byType(Scrollable).first,
      );
    } else {
      await tester.ensureVisible(finder);
    }
    await tester.pumpAndSettle();
  }

  bool? checkboxValue(WidgetTester tester) =>
      tester.widget<CheckboxListTile>(find.byKey(kFinished)).value;

  testWidgets('a new book can be marked finished, saved and seen on detail', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildLibrary();
    await pumpApp(tester, controller);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'New book');
    await tester.pumpAndSettle();

    await show(tester, find.byKey(kFinished));
    expect(checkboxValue(tester), isFalse);
    await tester.tap(find.byKey(kFinished));
    await tester.pumpAndSettle();
    expect(checkboxValue(tester), isTrue);

    await tester.tap(find.byKey(const Key('editor-save-bottom')));
    await tester.pumpAndSettle();
    expect((await repository.getItem(kItemId))!.isFinished, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>(kItemId)));
    await tester.pumpAndSettle();
    expect(find.text('Finished'), findsOneWidget);

    // Reopening the editor shows the stored value.
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(kFinished));
    expect(checkboxValue(tester), isTrue);
  });

  testWidgets('cancelling the editor keeps the stored flag', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildLibrary();
    await repository.createItem(
      sampleItem(id: kItemId, medium: MediaType.book, title: 'Dune'),
    );
    await controller.refresh();
    await pumpApp(tester, controller);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>(kItemId)));
    await tester.pumpAndSettle();
    expect(find.text('Not finished'), findsOneWidget);

    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(kFinished));
    await tester.tap(find.byKey(kFinished));
    await tester.pumpAndSettle();
    expect(checkboxValue(tester), isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect((await repository.getItem(kItemId))!.isFinished, isFalse);
    expect(find.text('Not finished'), findsOneWidget);
  });

  testWidgets('only books and films show the control', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, _) = await buildLibrary();
    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();

    for (final medium in MediaType.values) {
      final chip = find.byKey(Key('medium-${medium.wireValue}'));
      await show(tester, chip, delta: -160);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      if (medium.isFinishable) {
        await show(tester, find.byKey(kFinished));
        expect(find.byKey(kFinished), findsOneWidget, reason: medium.wireValue);
      } else {
        expect(find.byKey(kFinished), findsNothing, reason: medium.wireValue);
      }
    }
  });

  testWidgets('a hidden flag survives a medium change and comes back', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildLibrary(seedFinishedBook: true);
    await pumpApp(tester, controller);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>(kItemId)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(kFinished));
    expect(checkboxValue(tester), isTrue);

    // Switch to a medium with no finished state: the control disappears, the
    // draft value stays, and saving keeps it in storage.
    final cdChip = find.byKey(const Key('medium-cd'));
    await show(tester, cdChip, delta: -160);
    await tester.tap(cdChip);
    await tester.pumpAndSettle();
    expect(find.byKey(kFinished), findsNothing);
    await tester.tap(find.byKey(const Key('editor-save-bottom')));
    await tester.pumpAndSettle();

    final stored = (await repository.getItem(kItemId))!;
    expect(stored.medium, MediaType.cd);
    expect(stored.isFinished, isTrue);

    // Saving an edit that was opened from the detail route returns to that
    // detail route, so switch back to a finishable medium from there.
    expect(find.byKey(const Key('detail-edit')), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();
    final bookChip = find.byKey(const Key('medium-book'));
    await show(tester, bookChip, delta: -160);
    await tester.tap(bookChip);
    await tester.pumpAndSettle();
    await show(tester, find.byKey(kFinished));
    expect(checkboxValue(tester), isTrue);
  });

  testWidgets('a metadata lookup keeps the finished flag', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final metadata = MetadataService(
      providers: <MetadataProvider>[
        StubMetadataProvider(
          candidates: <MetadataCandidate>[
            stubCandidate(title: 'Dune (provider)', year: 1965),
          ],
        ),
      ],
    );
    final (controller, repository) = await buildLibrary(seedFinishedBook: true);
    await pumpApp(
      tester,
      controller,
      services: testServices(repository: repository, metadata: metadata),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>(kItemId)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-edit')));
    await tester.pumpAndSettle();

    await show(tester, find.byKey(const Key('field-barcode')));
    await tester.enterText(
      find.byKey(const Key('field-barcode')),
      '9780306406157',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('field-barcode-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('candidate-stub:record-1')));
    await tester.pumpAndSettle();

    // The title field may be scrolled out of view after the candidate was
    // applied; check the field's own value, then the persisted item below.
    await show(tester, find.byKey(const Key('field-title')), delta: -160);
    final titleField = tester.widget<TextField>(
      find.byKey(const Key('field-title')),
    );
    expect(titleField.controller!.text, 'Dune (provider)');
    await show(tester, find.byKey(kFinished));
    expect(checkboxValue(tester), isTrue);

    await tester.tap(find.byKey(const Key('editor-save-bottom')));
    await tester.pumpAndSettle();
    final stored = (await repository.getItem(kItemId))!;
    expect(stored.title, 'Dune (provider)');
    expect(stored.isFinished, isTrue);
  });

  testWidgets('a finished book at 320px with 1.6x text stays usable', (
    tester,
  ) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildLibrary();
    await pumpApp(tester, controller);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-title')), 'Narrow book');
    await tester.pumpAndSettle();
    await show(tester, find.byKey(kFinished));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(kFinished));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(checkboxValue(tester), isTrue);

    await tester.tap(find.byKey(const Key('editor-save-bottom')));
    await tester.pumpAndSettle();
    expect((await repository.getItem(kItemId))!.isFinished, isTrue);
  });
}
