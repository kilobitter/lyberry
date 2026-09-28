import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/state/movie_search_controller.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/screens/movie_search_screen.dart';

import '../support/fake_movies.dart';
import '../support/fake_web.dart';
import '../support/in_memory_repository.dart';
import '../support/stub_provider.dart';
import '../support/test_support.dart';

/// A European EAN-13 that must stay in the request path unchanged.
const String kMovieEan = '5051888100639';

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

  LookupQuery movieQuery({MediaType? medium = MediaType.bluray}) => LookupQuery(
    identifier: IdentifierNormalizer.normalize(kMovieEan),
    mediumHint: medium,
  );

  Future<void> pumpCandidates(
    WidgetTester tester, {
    required FakeMovieCatalog movies,
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
        movies: movies,
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

  testWidgets('movie title search sends the typed title and optional year', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final movies = FakeMovieCatalog(
      candidates: <MetadataCandidate>[
        movieCandidate(
          title: 'The Matrix',
          identity: 'code:883929638482',
          format: '4K UHD + Blu-ray',
          year: 1999,
          creator: 'Lana Wachowski',
          matchKind: MatchKind.possible,
        ),
      ],
    );
    await pumpCandidates(tester, movies: movies, query: movieQuery());

    expect(find.byKey(const Key('candidates-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('candidates-movie-title-search')));
    await tester.pumpAndSettle();

    expect(find.byType(MovieSearchScreen), findsOneWidget);
    // The scanned code stays on screen and nothing is requested yet.
    expect(find.text(kMovieEan), findsOneWidget);
    expect(movies.queries, isEmpty);

    await tester.enterText(
      find.byKey(const Key('movie-search-field')),
      'The Matrix',
    );
    await tester.enterText(find.byKey(const Key('movie-search-year')), '1999');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();

    expect(movies.queries, <String>['The Matrix']);
    expect(movies.years, <int?>[1999]);
    expect(find.text('The Matrix'), findsWidgets);
    expect(find.textContaining('4K UHD + Blu-ray | 1999'), findsOneWidget);

    await tester.tap(find.text('Use this'));
    await tester.pumpAndSettle();
    // The choice travelled back through the candidates screen, so the scanned
    // code now reaches the editor with the chosen candidate.
    expect(find.byType(MovieSearchScreen), findsNothing);
  });

  testWidgets('the movie action appears only for movie or unknown codes', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));

    for (final hint in <MediaType?>[MediaType.dvd, MediaType.bluray, null]) {
      await pumpCandidates(
        tester,
        movies: FakeMovieCatalog(),
        query: movieQuery(medium: hint),
      );
      expect(
        find.byKey(const Key('candidates-movie-title-search')),
        findsOneWidget,
        reason: 'hint $hint',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    for (final hint in <MediaType?>[MediaType.book, MediaType.game]) {
      await pumpCandidates(
        tester,
        movies: FakeMovieCatalog(),
        query: movieQuery(medium: hint),
      );
      expect(
        find.byKey(const Key('candidates-movie-title-search')),
        findsNothing,
        reason: 'hint $hint',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    // An ISBN is never a movie, whatever hint came with it.
    await pumpCandidates(
      tester,
      movies: FakeMovieCatalog(),
      query: LookupQuery(
        identifier: IdentifierNormalizer.normalize('9780306406157'),
        mediumHint: null,
      ),
    );
    expect(
      find.byKey(const Key('candidates-movie-title-search')),
      findsNothing,
    );
  });

  testWidgets('the action is offered next to unwanted matches too', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpCandidates(
      tester,
      movies: FakeMovieCatalog(),
      query: movieQuery(),
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
      find.byKey(const Key('candidates-movie-title-search')),
      findsOneWidget,
    );
  });

  testWidgets('a missing key explains setup and sends no request', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final movies = FakeMovieCatalog(configured: false);
    await pumpCandidates(tester, movies: movies, query: movieQuery());

    await tester.tap(find.byKey(const Key('candidates-movie-title-search')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('movie-search-missing-key')), findsOneWidget);
    expect(find.byKey(const Key('movie-search-open-settings')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('movie-search-field')),
      'Alien',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();
    expect(movies.queries, isEmpty);

    // Returning from Settings re-reads the credential state, so a key saved
    // there takes effect without an app restart.
    await tester.tap(find.byKey(const Key('movie-search-open-settings')));
    await tester.pumpAndSettle();
    // We are on the Settings route (its backup section is always built).
    expect(find.byKey(const Key('settings-export')), findsOneWidget);
    movies.configured = true;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movie-search-missing-key')), findsNothing);

    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();
    expect(movies.queries, <String>['Alien']);
  });

  testWidgets('the optional year must be a plausible four-digit year', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final movies = FakeMovieCatalog();
    await pumpCandidates(tester, movies: movies, query: movieQuery());
    await tester.tap(find.byKey(const Key('candidates-movie-title-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('movie-search-field')),
      'Alien',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('movie-search-submit')))
          .onPressed,
      isNotNull,
    );

    await tester.enterText(find.byKey(const Key('movie-search-year')), '19');
    await tester.pumpAndSettle();
    expect(
      find.text('Use a four-digit year, or leave it empty.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('movie-search-submit')))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('movie-search-year')), '1200');
    await tester.pumpAndSettle();
    expect(find.textContaining('Use a year between'), findsOneWidget);
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();
    expect(movies.queries, isEmpty);
  });

  testWidgets('repeated failures keep every message and a retry', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final movies = FakeMovieCatalog(
      failure: const LookupFailure(
        providerId: 'upcmdb',
        providerLabel: 'UPCMDB',
        kind: LookupFailureKind.quota,
        message: 'UPCMDB is rate limiting this device. Try again later.',
      ),
    );
    await pumpCandidates(tester, movies: movies, query: movieQuery());
    await tester.tap(find.byKey(const Key('candidates-movie-title-search')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('movie-search-field')),
      'Alien',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movie-search-empty')), findsOneWidget);
    expect(find.textContaining('rate limiting'), findsOneWidget);

    await tester.tap(find.byKey(const Key('movie-search-retry')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('rate limiting'), findsOneWidget);
    expect(movies.queries, <String>['Alien', 'Alien']);
  });

  testWidgets('a disposed title search ignores its late answer', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final movies = FakeMovieCatalog(
      delay: const Duration(milliseconds: 200),
      candidates: <MetadataCandidate>[
        movieCandidate(title: 'Late movie', identity: 'code:1'),
      ],
    );
    await pumpCandidates(tester, movies: movies, query: movieQuery());
    await tester.tap(find.byKey(const Key('candidates-movie-title-search')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('movie-search-field')), 'Late');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the movie search screen fits 320px at 1.6x text', (
    tester,
  ) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final movies = FakeMovieCatalog(
      candidates: <MetadataCandidate>[
        movieCandidate(
          title:
              'The Lord of the Rings: The Fellowship of the Ring (Extended '
              'Edition)',
          identity: 'code:883929638482',
          format: '4K Ultra HD + Blu-ray + Digital Copy',
          year: 2001,
          creator: 'Peter Jackson',
        ),
      ],
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(repository: repository, movies: movies),
    );
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => MovieSearchScreen(
              identifier: IdentifierNormalizer.normalize(kMovieEan),
              mediumHint: MediaType.bluray,
            ),
          ),
        );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.enterText(
      find.byKey(const Key('movie-search-field')),
      'The Lord of the Rings',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Use this'),
      140,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Use this'), findsOneWidget);
  });

  testWidgets('movie credential changes invalidate cached movie state', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final movies = FakeMovieCatalog();
    final keys = InMemoryApiKeyStore();
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        movies: movies,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-upcmdb-field')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('settings-upcmdb-status'))).data,
      'Not configured',
    );
    await tester.enterText(
      find.byKey(const Key('settings-upcmdb-field')),
      'upcmdb-synthetic',
    );
    await tester.tap(find.byKey(const Key('settings-upcmdb-save')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('settings-upcmdb-status'))).data,
      'Saved',
    );
    expect(keys.peek(MovieKeyProvider.upcmdb), 'upcmdb-synthetic');
    expect(movies.invalidations, greaterThan(0));

    await tester.tap(find.byKey(const Key('settings-upcmdb-remove')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('settings-upcmdb-status'))).data,
      'Not configured',
    );
    expect(keys.peek(MovieKeyProvider.upcmdb), isNull);
    expect(find.byKey(const Key('settings-movies-key-note')), findsOneWidget);
    expect(
      find.byKey(const Key('settings-movies-attribution')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings-movies-pricing')), findsOneWidget);
    expect(find.byKey(const Key('settings-movies-api-docs')), findsOneWidget);
  });

  testWidgets('a movie storage failure is surfaced without leaking a value', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final keys = InMemoryApiKeyStore();
    keys.writeFailure = const WebLookupException(
      WebFailureKind.unavailable,
      'UPCMDB API key could not be saved on this device.',
      stage: WebLookupStage.keys,
    );
    final movies = FakeMovieCatalog();
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        movies: movies,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-upcmdb-field')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-upcmdb-field')),
      'upcmdb-should-not-appear',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('settings-upcmdb-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-upcmdb-save')));
    await tester.pumpAndSettle();

    expect(keys.peek(MovieKeyProvider.upcmdb), isNull);
    expect(
      tester.widget<Text>(find.byKey(const Key('settings-upcmdb-status'))).data,
      'Not configured',
    );
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .join('|');
    expect(rendered, isNot(contains('upcmdb-should-not-appear')));
  });

  test('a late success for edited fields is dropped', () async {
    final catalog = FakeMovieCatalog(
      delay: const Duration(milliseconds: 80),
      candidates: <MetadataCandidate>[
        movieCandidate(title: 'Late movie', identity: 'code:1'),
      ],
    );
    final controller = MovieSearchController(
      catalog: catalog,
      clock: FixedClock(kBaseTime),
    );
    addTearDown(controller.dispose);

    controller.setTitle('Alien');
    final pending = controller.submit();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.setTitle('Aliens');
    await pending;

    expect(catalog.queries, <String>['Alien']);
    expect(controller.candidates, isEmpty);
    expect(controller.errorMessage, isNull);
    expect(controller.status, MovieSearchStatus.idle);
  });

  test('a late error for edited fields is dropped', () async {
    final catalog = FakeMovieCatalog(
      delay: const Duration(milliseconds: 80),
      throwOnSearch: StateError('synthetic late failure'),
    );
    final controller = MovieSearchController(
      catalog: catalog,
      clock: FixedClock(kBaseTime),
    );
    addTearDown(controller.dispose);

    controller.setTitle('Alien');
    final pending = controller.submit();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.setTitle('Aliens');
    await pending;

    expect(controller.errorMessage, isNull);
    expect(controller.status, MovieSearchStatus.idle);
  });

  test('a second submit while the first is running is ignored', () async {
    final catalog = FakeMovieCatalog(delay: const Duration(milliseconds: 60));
    final controller = MovieSearchController(
      catalog: catalog,
      clock: FixedClock(kBaseTime),
    );
    addTearDown(controller.dispose);

    controller.setTitle('Alien');
    final first = controller.submit();
    await controller.submit();
    await first;

    expect(catalog.queries, <String>['Alien']);
  });
}
