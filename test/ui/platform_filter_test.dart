import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/state/library_controller.dart';

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

  Future<InMemoryMediaRepository> seededRepository() async {
    final repository = InMemoryMediaRepository();
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        medium: MediaType.game,
        title: 'Station Game',
        platform: 'PlayStation 4',
        createdAt: '2026-09-23T10:00:00.000Z',
        updatedAt: '2026-09-23T10:00:00.000Z',
      ),
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000002',
        medium: MediaType.game,
        title: 'Station Game Two',
        // Same platform with different casing/whitespace: one option only.
        platform: '  playstation   4  ',
        createdAt: '2026-09-23T11:00:00.000Z',
        updatedAt: '2026-09-23T11:00:00.000Z',
      ),
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000003',
        medium: MediaType.game,
        title: 'Retro Game',
        platform: 'Super Nintendo',
        createdAt: '2026-09-23T12:00:00.000Z',
        updatedAt: '2026-09-23T12:00:00.000Z',
      ),
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000004',
        medium: MediaType.game,
        title: 'Blank Platform Game',
        platform: '   ',
        createdAt: '2026-09-23T13:00:00.000Z',
        updatedAt: '2026-09-23T13:00:00.000Z',
      ),
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000005',
        medium: MediaType.book,
        title: 'A Book',
        publisher: 'Chilton',
        createdAt: '2026-09-23T14:00:00.000Z',
        updatedAt: '2026-09-23T14:00:00.000Z',
      ),
    );
    return repository;
  }

  Future<LibraryController> startedController(
    InMemoryMediaRepository repository,
  ) async {
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    return controller;
  }

  group('platform options', () {
    test('come from games only, deduped, sorted, blanks skipped', () async {
      final repository = await seededRepository();
      final controller = await startedController(repository);

      await controller.setMediumFilter(MediaType.game);
      expect(controller.availableGamePlatforms, <String>[
        'PlayStation 4',
        'Super Nintendo',
      ]);
      // The readable spelling of the first occurrence is retained.
      expect(controller.availableGamePlatforms.first, 'PlayStation 4');

      // Non-game rows never contribute options.
      expect(controller.availableGamePlatforms, isNot(contains('Chilton')));
    });

    test('are empty outside the Games tab', () async {
      final repository = await seededRepository();
      final controller = await startedController(repository);
      expect(controller.availableGamePlatforms, isEmpty);
    });

    test('prefer mixed case and a readable fallback for duplicates', () async {
      Future<List<String>> optionsFor(List<String> spellings) async {
        final repository = InMemoryMediaRepository();
        for (var index = 0; index < spellings.length; index++) {
          await repository.createItem(
            sampleItem(
              id: '00000000-0000-4000-8000-${(1000 + index).toString().padLeft(12, '0')}',
              medium: MediaType.game,
              title: 'Game $index',
              platform: spellings[index],
              createdAt: '2026-09-23T10:00:00.000Z',
              updatedAt: '2026-09-23T10:00:00.000Z',
            ),
          );
        }
        final controller = await startedController(repository);
        await controller.setMediumFilter(MediaType.game);
        return controller.availableGamePlatforms;
      }

      // A mixed-case spelling wins over shouted or lowercased duplicates
      // whatever order they arrive in.
      for (final spellings in <List<String>>[
        <String>['PLAYSTATION 4', 'playstation 4', 'PlayStation 4'],
        <String>['playstation 4', 'PlayStation 4', 'PLAYSTATION 4'],
        <String>['PlayStation 4', 'PLAYSTATION 4', 'playstation 4'],
      ]) {
        expect(await optionsFor(spellings), <String>['PlayStation 4']);
      }

      // With no mixed spelling the fallback stays deterministic and readable:
      // an all-upper abbreviation is not shouted down by an all-lower entry,
      // and the stored value is never rewritten.
      expect(await optionsFor(<String>['nes', 'NES']), <String>['NES']);
      expect(await optionsFor(<String>['NES', 'nes']), <String>['NES']);
    });
  });

  group('platform predicate', () {
    test('combines with search and All removes only the platform', () async {
      final repository = await seededRepository();
      final controller = await startedController(repository);

      await controller.setMediumFilter(MediaType.game);
      expect(controller.items, hasLength(4));

      await controller.setSearch('Station');
      expect(controller.items, hasLength(2));

      await controller.setPlatformFilter('PlayStation 4');
      expect(controller.platformFilter, 'PlayStation 4');
      expect(controller.items, hasLength(2));

      await controller.setSearch('Two');
      expect(controller.items, hasLength(1));
      expect(controller.items.single.title, 'Station Game Two');

      await controller.setPlatformFilter(null);
      expect(controller.platformFilter, isNull);
      expect(controller.items, hasLength(1));
      expect(controller.items.single.title, 'Station Game Two');
    });

    test('a blank or unknown platform resolves to All', () async {
      final repository = await seededRepository();
      final controller = await startedController(repository);
      await controller.setMediumFilter(MediaType.game);

      await controller.setPlatformFilter('PlayStation 4');
      expect(controller.platformFilter, 'PlayStation 4');

      await controller.setPlatformFilter('   ');
      expect(controller.platformFilter, isNull);
      expect(controller.items, hasLength(4));

      await controller.setPlatformFilter('Nintendo Switch');
      expect(controller.platformFilter, isNull);
    });

    test('leaving Games and clearing filters reset the selection', () async {
      final repository = await seededRepository();
      final controller = await startedController(repository);
      await controller.setMediumFilter(MediaType.game);
      await controller.setPlatformFilter('Super Nintendo');
      expect(controller.items, hasLength(1));

      await controller.setMediumFilter(MediaType.book);
      expect(controller.platformFilter, isNull);
      expect(controller.mediumFilter, MediaType.book);
      expect(controller.availableGamePlatforms, isEmpty);

      await controller.setMediumFilter(MediaType.game);
      await controller.setSearch('Retro');
      await controller.setPlatformFilter('Super Nintendo');
      await controller.clearFilters();
      expect(controller.platformFilter, isNull);
      expect(controller.mediumFilter, isNull);
      expect(controller.search, isEmpty);
      expect(controller.hasFilters, isFalse);
      expect(controller.items, hasLength(5));
    });

    test(
      'deleting the last entry on the selected platform falls back',
      () async {
        final repository = await seededRepository();
        final controller = await startedController(repository);
        await controller.setMediumFilter(MediaType.game);
        await controller.setPlatformFilter('PlayStation 4');
        expect(controller.items, hasLength(2));

        // While the games tab is active, remove the platform in one step: both
        // PlayStation entries go, so the option disappears with them.
        await repository.updateItem(
          sampleItem(
            id: '00000000-0000-4000-8000-000000000001',
            medium: MediaType.game,
            title: 'Station Game',
            platform: 'Super Nintendo',
            createdAt: '2026-09-23T10:00:00.000Z',
            updatedAt: '2026-09-23T15:00:00.000Z',
          ),
        );
        await repository.deleteItem('00000000-0000-4000-8000-000000000002');
        await controller.refresh();

        expect(controller.availableGamePlatforms, <String>['Super Nintendo']);
        expect(controller.platformFilter, isNull);
        expect(controller.items, hasLength(3));
      },
    );

    test(
      'a casing-only option change keeps the exact refreshed value',
      () async {
        final repository = await seededRepository();
        final controller = await startedController(repository);
        await controller.setMediumFilter(MediaType.game);
        await controller.setPlatformFilter('PlayStation 4');
        expect(controller.items, hasLength(2));

        // The entry carrying the canonical spelling goes; an equivalent
        // lowercased entry remains, so the logical filter must survive while the
        // published value becomes the exact spelling of the refreshed option.
        await repository.deleteItem('00000000-0000-4000-8000-000000000001');
        await controller.refresh();

        expect(controller.availableGamePlatforms, <String>[
          'playstation 4',
          'Super Nintendo',
        ]);
        expect(controller.platformFilter, 'playstation 4');
        expect(controller.items, hasLength(1));
        expect(controller.items.single.title, 'Station Game Two');
      },
    );

    test('a stale reload cannot overwrite a newer selection', () async {
      final repository = await seededRepository();
      final controller = await startedController(repository);
      await controller.setMediumFilter(MediaType.game);

      repository.listItemsDelay = const Duration(milliseconds: 80);
      final slow = controller.setPlatformFilter('Super Nintendo');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final fast = controller.setMediumFilter(MediaType.book);
      await Future.wait<void>(<Future<void>>[slow, fast]);

      // The later choice wins; the slow games reload is discarded by the token.
      expect(controller.mediumFilter, MediaType.book);
      expect(controller.platformFilter, isNull);
      expect(controller.availableGamePlatforms, isEmpty);
      expect(controller.items.single.title, 'A Book');
    });
  });

  group('home dropdown', () {
    Future<LibraryController> pumpHome(
      WidgetTester tester,
      InMemoryMediaRepository repository,
    ) async {
      final controller = await startedController(repository);
      await pumpApp(tester, controller);
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('appears only for Games and filters the grid', (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final repository = await seededRepository();
      await pumpHome(tester, repository);

      expect(find.byKey(const Key('home-platform')), findsNothing);

      await tester.tap(find.text('Games'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-platform')), findsOneWidget);
      expect(find.text('All platforms'), findsOneWidget);
      expect(find.text('Blank Platform Game'), findsOneWidget);
      expect(find.text('A Book'), findsNothing);

      await tester.tap(find.byKey(const Key('home-platform')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Super Nintendo').last);
      await tester.pumpAndSettle();

      expect(find.text('Retro Game'), findsOneWidget);
      expect(find.text('Station Game'), findsNothing);
      expect(find.text('Blank Platform Game'), findsNothing);

      // Leaving Games removes the dropdown and the predicate.
      await tester.tap(find.text('Books'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-platform')), findsNothing);
      expect(find.text('A Book'), findsOneWidget);
    });

    testWidgets('keeps a valid exact selection when the spelling changes', (
      tester,
    ) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final repository = await seededRepository();
      final controller = await pumpHome(tester, repository);

      await tester.tap(find.text('Games'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-platform')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PlayStation 4').last);
      await tester.pumpAndSettle();
      expect(find.text('Station Game'), findsOneWidget);
      expect(find.text('Station Game Two'), findsOneWidget);

      // The canonical spelling disappears while an equivalent lowercased
      // platform survives: the logical filter must hold and the dropdown must
      // keep an exact, valid value instead of asserting on a stale string.
      await repository.deleteItem('00000000-0000-4000-8000-000000000001');
      await controller.refresh();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final dropdown = tester.widget<DropdownButton<String?>>(
        find.byKey(const Key('home-platform')),
      );
      expect(dropdown.value, 'playstation 4');
      expect(controller.platformFilter, 'playstation 4');
      expect(find.text('Station Game Two'), findsOneWidget);
      expect(find.text('Station Game'), findsNothing);
    });

    testWidgets('is disabled when no game names a platform', (tester) async {
      useSurface(tester);
      addTearDown(() => resetSurface(tester));
      final repository = InMemoryMediaRepository();
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000010',
          medium: MediaType.game,
          title: 'Platform-less Game',
          platform: '   ',
          createdAt: '2026-09-23T10:00:00.000Z',
          updatedAt: '2026-09-23T10:00:00.000Z',
        ),
      );
      await pumpHome(tester, repository);

      await tester.tap(find.text('Games'));
      await tester.pumpAndSettle();
      final dropdown = tester.widget<DropdownButton<String?>>(
        find.byKey(const Key('home-platform')),
      );
      expect(dropdown.onChanged, isNull);
      expect(find.text('All platforms'), findsOneWidget);
      // The platform-less game is still visible under All.
      expect(find.text('Platform-less Game'), findsOneWidget);
    });

    testWidgets('a long platform name fits 320px at 1.6x text', (tester) async {
      useSurface(tester, size: const Size(320, 568), textScale: 1.6);
      addTearDown(() => resetSurface(tester));
      final repository = InMemoryMediaRepository();
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000020',
          medium: MediaType.game,
          title: 'Long Platform Game',
          platform: 'Super Nintendo Entertainment System - Super Famicom (PAL)',
          createdAt: '2026-09-23T10:00:00.000Z',
          updatedAt: '2026-09-23T10:00:00.000Z',
        ),
      );
      await pumpHome(tester, repository);

      await tester.scrollUntilVisible(
        find.text('Games'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Games'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('home-platform')),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('home-platform')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Super Nintendo Entertainment System'),
        findsWidgets,
      );
    });
  });
}
