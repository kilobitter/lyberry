import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/screens/movie_search_screen.dart';

import '../support/fake_movies.dart';
import '../support/fake_web.dart';
import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

const String kMovieEan = '5051888100639';

// Renders the movie surfaces for review.
// Run with: flutter test --update-goldens test/golden/movies_render_test.dart
// The PNGs are copied into docs/agent-work/lyberry/evidence/movies/.
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

  Future<void> pumpMovieSearch(
    WidgetTester tester, {
    required FakeMovieCatalog movies,
  }) async {
    final repository = InMemoryMediaRepository();
    final controller = await library(repository);
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
  }

  List<MetadataCandidate> syntheticMovies() => <MetadataCandidate>[
    movieCandidate(
      // Clearly synthetic fixtures: they must not read as live coverage.
      title: 'Synthetic Edition Film',
      identity: 'code:883929638482',
      format: '4K UHD + Blu-ray',
      edition: '4K Ultra HD + Blu-ray (Repackaged)',
      year: 1999,
      creator: 'Synthetic Director',
      matchKind: MatchKind.possible,
    ),
    movieCandidate(
      title: 'Synthetic Edition Film',
      identity: 'code:883929638499',
      format: 'DVD',
      edition: 'DVD (Repackaged)',
      year: 1999,
      creator: 'Synthetic Director',
      matchKind: MatchKind.possible,
    ),
  ];

  testWidgets('movie title search at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpMovieSearch(tester, movies: FakeMovieCatalog());
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/movies_title_search_390x844.png'),
    );
  });

  testWidgets('movie title search results at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpMovieSearch(
      tester,
      movies: FakeMovieCatalog(candidates: syntheticMovies()),
    );
    await tester.enterText(
      find.byKey(const Key('movie-search-field')),
      'Synthetic Edition Film',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/movies_title_search_results_390x844.png'),
    );
  });

  testWidgets('movie title search at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    await pumpMovieSearch(
      tester,
      movies: FakeMovieCatalog(candidates: syntheticMovies()),
    );
    await tester.enterText(
      find.byKey(const Key('movie-search-field')),
      'Synthetic Edition Film',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('movie-search-submit')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      // The second (DVD) result, by its exact candidate key.
      find.byKey(const Key('movie-result-use-upcmdb:code:883929638499|dvd')),
      140,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/movies_title_search_320x568_scale1.6.png'),
    );
  });

  testWidgets('movie title search without a key at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpMovieSearch(tester, movies: FakeMovieCatalog(configured: false));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/movies_missing_key_390x844.png'),
    );
  });

  testWidgets('movie credentials settings at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await library(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        movies: FakeMovieCatalog(),
        keys: InMemoryApiKeyStore(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-movies-attribution')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_movies_keys_390x844.png'),
    );
  });
}
