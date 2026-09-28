import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/screens/game_search_screen.dart';

import '../support/fake_games.dart';
import '../support/fake_web.dart';
import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

const String kWiiUpc = '045496367619';

// Renders the games surfaces for review.
// Run with: flutter test --update-goldens test/golden/games_render_test.dart
// The PNGs are copied into docs/agent-work/lyberry/evidence/games/.
void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  Future<LibraryController> library(InMemoryMediaRepository repository) async {
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    return controller;
  }

  Future<void> pumpGameSearch(
    WidgetTester tester, {
    required FakeGameCatalog games,
  }) async {
    final repository = InMemoryMediaRepository();
    final controller = await library(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(repository: repository, games: games),
    );
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => GameSearchScreen(
              identifier: IdentifierNormalizer.normalize(kWiiUpc),
              mediumHint: MediaType.game,
            ),
          ),
        );
    await tester.pumpAndSettle();
  }

  testWidgets('game title search at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpGameSearch(tester, games: FakeGameCatalog());
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/games_title_search_390x844.png'),
    );
  });

  testWidgets('game title search results at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpGameSearch(
      tester,
      games: FakeGameCatalog(
        candidates: <MetadataCandidate>[
          gameCandidate(
            // Clearly synthetic cross-platform fixture: it must not read as a
            // real game's platform list.
            title: 'Synthetic Cross-Platform Game',
            gameId: 7346,
            platformId: 5,
            platformName: 'Wii',
            year: 2009,
          ),
          gameCandidate(
            title: 'Synthetic Cross-Platform Game',
            gameId: 7346,
            platformId: 7,
            platformName: 'PlayStation 4',
            year: 2013,
          ),
        ],
      ),
    );
    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Synthetic Cross-Platform Game',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/games_title_search_results_390x844.png'),
    );
  });

  testWidgets('game title search at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    await pumpGameSearch(
      tester,
      games: FakeGameCatalog(
        candidates: <MetadataCandidate>[
          gameCandidate(
            title: 'Wii Sports Resort',
            gameId: 7346,
            platformId: 5,
            platformName: 'Wii',
            year: 2009,
          ),
        ],
      ),
    );
    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Wii Sports Resort',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Use this'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/games_title_search_320x568_scale1.6.png'),
    );
  });

  testWidgets('games credentials settings at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await library(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        games: FakeGameCatalog(),
        keys: InMemoryApiKeyStore(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-games-attribution')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_games_keys_390x844.png'),
    );
  });

  testWidgets('games credentials settings at 320x568 with 1.6x text', (
    tester,
  ) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await library(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        games: FakeGameCatalog(),
        keys: InMemoryApiKeyStore(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-games-key-note')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_games_keys_320x568_scale1.6.png'),
    );
  });
}
