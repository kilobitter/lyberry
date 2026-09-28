import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/screens/game_search_screen.dart';
import 'package:lyberry/ui/screens/scan_screen.dart';

import '../support/fake_scan_camera.dart';
import '../support/fake_games.dart';
import '../support/fake_web.dart';
import '../support/in_memory_repository.dart';
import '../support/stub_provider.dart';
import '../support/test_support.dart';

const String kWiiUpc = '045496367619';

void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  Future<(LibraryController, InMemoryMediaRepository)> buildLibrary() async {
    final repository = InMemoryMediaRepository();
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    return (controller, repository);
  }

  LookupQuery gameQuery({MediaType? medium = MediaType.game}) => LookupQuery(
    identifier: IdentifierNormalizer.normalize(kWiiUpc),
    mediumHint: medium,
  );

  Future<void> pumpCandidates(
    WidgetTester tester, {
    required FakeGameCatalog games,
    required LookupQuery query,
    MetadataService? metadata,
    InMemoryApiKeyStore? keys,
  }) async {
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys ?? InMemoryApiKeyStore(),
        games: games,
        metadata:
            metadata ?? MetadataService(providers: const <MetadataProvider>[]),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => CandidatesScreen(query: query),
          ),
        );
    await tester.pumpAndSettle();
  }

  /// Scrolls lazily built editor content into view before reading or tapping it.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      final scrollable = find.byType(Scrollable).first;
      await tester.drag(scrollable, const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(finder, 140, scrollable: scrollable);
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('title search keeps the scanned code and saves nothing', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog(
      candidates: <MetadataCandidate>[
        gameCandidate(
          title: 'Wii Sports Resort',
          gameId: 7346,
          platformId: 5,
          platformName: 'Wii',
          year: 2009,
        ),
      ],
    );
    await pumpCandidates(tester, games: games, query: gameQuery());

    expect(find.byKey(const Key('candidates-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();
    expect(find.byType(GameSearchScreen), findsOneWidget);
    expect(find.text(kWiiUpc), findsOneWidget);

    // Nothing is requested until the explicit submit.
    expect(games.queries, isEmpty);
    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Wii Sports Resort',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();

    expect(games.queries, <String>['Wii Sports Resort']);
    expect(find.text('Wii Sports Resort'), findsWidgets);
    expect(find.textContaining('Wii | 2009'), findsOneWidget);

    await tester.tap(find.text('Use this'));
    await tester.pumpAndSettle();

    // The choice travelled back through the candidates screen.
    expect(find.byType(GameSearchScreen), findsNothing);
  });

  testWidgets('missing Twitch credentials explain setup without a request', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog(configured: false);
    await pumpCandidates(tester, games: games, query: gameQuery());

    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-search-missing-key')), findsOneWidget);
    expect(find.byKey(const Key('game-search-open-settings')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Wii Sports Resort',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();
    expect(games.queries, isEmpty);
  });

  testWidgets('a disposed title search ignores its late answer', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog(
      delay: const Duration(milliseconds: 200),
      candidates: <MetadataCandidate>[
        gameCandidate(title: 'Late game', gameId: 1),
      ],
    );
    await pumpCandidates(tester, games: games, query: gameQuery());

    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('game-search-field')), 'Late');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pump(const Duration(milliseconds: 20));

    // Leave the screen before the answer arrives.
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('unwanted matches still offer the title search', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog();
    await pumpCandidates(
      tester,
      games: games,
      query: gameQuery(),
      metadata: MetadataService(
        providers: <MetadataProvider>[
          StubMetadataProvider(
            id: 'upcitemdb',
            label: 'UPCitemdb',
            roles: const <ProviderRole>{ProviderRole.general},
            candidates: <MetadataCandidate>[stubCandidate(title: 'Other item')],
          ),
        ],
      ),
    );

    expect(
      find.byKey(const Key('candidates-game-title-search')),
      findsOneWidget,
    );
  });

  testWidgets('book lookups do not offer a game title search', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpCandidates(
      tester,
      games: FakeGameCatalog(),
      query: LookupQuery(
        identifier: IdentifierNormalizer.normalize('9780306406157'),
        mediumHint: MediaType.book,
      ),
    );
    expect(find.byKey(const Key('candidates-game-title-search')), findsNothing);
  });

  testWidgets('games credential changes invalidate cached games state', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog();
    final keys = InMemoryApiKeyStore();
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(repository: repository, keys: keys, games: games),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-scandex-field')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('settings-scandex-status')))
          .data,
      'Not configured',
    );
    await tester.enterText(
      find.byKey(const Key('settings-scandex-field')),
      'scandex-synthetic',
    );
    await tester.tap(find.byKey(const Key('settings-scandex-save')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('settings-scandex-status')))
          .data,
      'Saved',
    );
    expect(keys.peek(GamesKeyProvider.scandex), 'scandex-synthetic');
    expect(games.invalidations, greaterThan(0));

    await tester.enterText(
      find.byKey(const Key('settings-twitchId-field')),
      'synthetic-client-id',
    );
    await tester.tap(find.byKey(const Key('settings-twitchId-save')));
    await tester.pumpAndSettle();
    expect(keys.peek(GamesKeyProvider.twitchId), 'synthetic-client-id');

    await tester.tap(find.byKey(const Key('settings-scandex-remove')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('settings-scandex-status')))
          .data,
      'Not configured',
    );
    expect(keys.peek(GamesKeyProvider.scandex), isNull);
    expect(find.byKey(const Key('settings-games-key-note')), findsOneWidget);
    expect(find.byKey(const Key('settings-games-attribution')), findsOneWidget);
  });

  testWidgets('a games storage failure is surfaced without leaking a value', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final keys = InMemoryApiKeyStore();
    keys.writeFailure = const WebLookupException(
      WebFailureKind.unavailable,
      'Games credential could not be saved on this device.',
      stage: WebLookupStage.keys,
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        games: FakeGameCatalog(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-twitchSecret-field')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-twitchSecret-field')),
      'synthetic-secret-value',
    );
    await tester.tap(find.byKey(const Key('settings-twitchSecret-save')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('settings-twitchSecret-status')))
          .data,
      'Not configured',
    );
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .join('|');
    expect(rendered, isNot(contains('synthetic-secret-value')));
  });

  testWidgets('returning from Settings with a saved key enables the search', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog(configured: false);
    await pumpCandidates(tester, games: games, query: gameQuery());

    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-search-missing-key')), findsOneWidget);

    // Open Settings, "save" a key, and come back: the screen must re-read the
    // credential state instead of staying disabled forever.
    await tester.tap(find.byKey(const Key('game-search-open-settings')));
    await tester.pumpAndSettle();
    games.configured = true;
    games.candidates = <MetadataCandidate>[
      gameCandidate(
        title: 'Synthetic Console Game',
        gameId: 7,
        platformId: 19,
        platformName: 'Super Nintendo',
        year: 1992,
      ),
    ];
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('game-search-missing-key')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Synthetic Console Game',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();
    expect(games.queries, <String>['Synthetic Console Game']);
    expect(find.textContaining('Super Nintendo'), findsWidgets);
  });

  testWidgets('editing the title clears results from the previous search', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog(
      candidates: <MetadataCandidate>[
        gameCandidate(
          title: 'Synthetic Console Game',
          gameId: 7,
          platformId: 19,
          platformName: 'Super Nintendo',
          year: 1992,
        ),
      ],
    );
    await pumpCandidates(tester, games: games, query: gameQuery());
    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Synthetic Console Game',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Use this'), findsOneWidget);

    // A different title must not keep showing the old answer.
    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Another title',
    );
    await tester.pumpAndSettle();
    expect(find.text('Use this'), findsNothing);
    expect(find.byKey(const Key('game-search-idle')), findsOneWidget);
  });

  testWidgets('a credential read failure is shown accurately', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog(
      configuredError: const ProviderException(
        LookupFailureKind.unavailable,
        'Twitch credentials could not be read on this device.',
      ),
    );
    await pumpCandidates(tester, games: games, query: gameQuery());
    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('game-search-key-message')))
          .data,
      'Twitch credentials could not be read on this device.',
    );
    expect(find.textContaining('CREDENTIALS UNAVAILABLE'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Synthetic Console Game',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();
    expect(games.queries, isEmpty);
  });

  testWidgets('a chosen game reaches the editor and saves only on demand', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog(
      candidates: <MetadataCandidate>[
        gameCandidate(
          title: 'Synthetic Console Game',
          gameId: 42,
          platformId: 7,
          platformName: 'PlayStation 4',
          year: 2013,
        ),
      ],
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        games: games,
        metadata: MetadataService(providers: const <MetadataProvider>[]),
      ),
    );
    await tester.pumpAndSettle();

    // Scan flow with a fake camera: type the code, look it up, no free match.
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ScanScreen(camera: FakeScanCamera()),
          ),
        );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scan-manual-field')), kWiiUpc);
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('candidates-empty')), findsOneWidget);

    // Title search and platform choice.
    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('game-search-field')),
      'Synthetic Console Game',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this'));
    await tester.pumpAndSettle();

    // The editor is prefilled and nothing is written yet.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('field-title')))
          .controller
          ?.text,
      'Synthetic Console Game',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('field-barcode')))
          .controller
          ?.text,
      kWiiUpc,
    );
    await reveal(tester, find.byKey(const Key('field-platform')));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('field-platform')))
          .controller
          ?.text,
      'PlayStation 4',
    );
    await reveal(tester, find.byKey(const Key('field-review')));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('field-review')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(await repository.countItems(), 0);

    // Save persists exactly those values.
    await reveal(tester, find.byKey(const Key('editor-save')));
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();
    expect(await repository.countItems(), 1);
    final saved = (await repository.listItems()).single;
    expect(saved.title, 'Synthetic Console Game');
    expect(saved.barcode, kWiiUpc);
    expect(saved.platform, 'PlayStation 4');
    expect(saved.medium, MediaType.game);
    expect(saved.review, isEmpty);
    expect(saved.notes, isEmpty);
    expect(saved.rating, isNull);
  });

  testWidgets('the manual fallback from title search keeps the scanned code', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final games = FakeGameCatalog();
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        games: games,
        metadata: MetadataService(providers: const <MetadataProvider>[]),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ScanScreen(camera: FakeScanCamera()),
          ),
        );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scan-manual-field')), kWiiUpc);
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('candidates-game-title-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('game-search-manual')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('field-barcode')))
          .controller
          ?.text,
      kWiiUpc,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('field-title')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(await repository.countItems(), 0);
  });
}
