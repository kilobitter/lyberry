import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/state/web_lookup_controller.dart';
import 'package:lyberry/ui/screens/web_lookup_screen.dart';

import '../support/fake_web.dart';
import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

const String kMatrix = '5051888100639';

// Renders the web lookup surfaces for review.
// Run with: flutter test --update-goldens test/golden/web_lookup_render_test.dart
// The PNGs are copied into docs/agent-work/lyberry/evidence/web-lookup/.
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

  Future<void> pumpWeb(
    WidgetTester tester, {
    required InMemoryMediaRepository repository,
    required InMemoryApiKeyStore keys,
    FakeApiTransport? transport,
    FakePageFetcher? pages,
    MediaType? mediumHint,
    WebLookupMode mode = WebLookupMode.search,
  }) async {
    final controller = await library(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport ?? FakeApiTransport(),
        pages: pages ?? FakePageFetcher(),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => WebLookupScreen(
              identifier: IdentifierNormalizer.normalize(kMatrix),
              mediumHint: mediumHint,
              initialMode: mode,
            ),
          ),
        );
    await tester.pumpAndSettle();
  }

  InMemoryApiKeyStore configuredKeys() => InMemoryApiKeyStore(
    initial: <WebKeyProvider, String>{
      WebKeyProvider.tavily: 'tvly-synthetic',
      WebKeyProvider.deepseek: 'sk-synthetic',
    },
  );

  testWidgets('web search idle at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: configuredKeys(),
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_search_idle_390x844.png'),
    );
  });

  testWidgets('web results at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(
            url: 'https://www.bol.com/nl/nl/p/matrix/1002004013068310',
            title: 'Matrix',
          ),
          tavilyResult(
            url: 'https://www.ibs.it/matrix-4-film-collection/5051891186415',
            title: 'Matrix 4 Film Collection',
          ),
        ]),
      )
      ..enqueue(
        'api.deepseek.com',
        deepSeekAnswer(<String, Object?>{
          'schemaVersion': 1,
          'barcode': kMatrix,
          'candidates': <Object?>[
            <String, Object?>{
              'sourceId': 's2',
              'title': 'Matrix 4 Film Collection',
              'medium': null,
              'creator': null,
              'year': null,
              'publisher': null,
              'description': null,
              'platform': null,
              'barcodeQuote': 'Barcode $kMatrix',
              'titleQuote': 'Matrix 4 Film Collection',
            },
          ],
        }),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://www.bol.com/nl/nl/p/matrix/1002004013068310',
        body: productHtml(
          title: 'Matrix',
          code: kMatrix,
          brand: 'Warner Bros.',
          released: '1999-06-17',
        ),
      )
      ..page(
        'https://www.ibs.it/matrix-4-film-collection/5051891186415',
        statusCode: 429,
        body: 'too many requests',
      );
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: configuredKeys(),
      transport: transport,
      pages: pages,
    );
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_results_390x844.png'),
    );
  });

  testWidgets('missing key state at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: InMemoryApiKeyStore(),
    );
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_missing_key_390x844.png'),
    );
  });

  testWidgets('web AI candidate at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(
            url: 'https://www.ibs.it/matrix-4-film-collection/5051891186415',
            title: 'Matrix 4 Film Collection',
          ),
        ]),
      )
      ..enqueue(
        'api.deepseek.com',
        deepSeekAnswer(<String, Object?>{
          'schemaVersion': 1,
          'barcode': kMatrix,
          'candidates': <Object?>[
            <String, Object?>{
              'sourceId': 's1',
              'title': 'Matrix 4 Film Collection',
              'medium': null,
              'creator': null,
              'year': null,
              'publisher': null,
              'description': null,
              'platform': null,
              'barcodeQuote': 'Codice 5051888100639',
              'titleQuote': 'Matrix 4 Film Collection',
            },
          ],
        }),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://www.ibs.it/matrix-4-film-collection/5051891186415',
        body:
            '<html><body><h1>Matrix 4 Film Collection</h1>'
            '<p>Codice 5051888100639. Edizione italiana.</p></body></html>',
      );
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: configuredKeys(),
      transport: transport,
      pages: pages,
    );
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_ai_result_390x844.png'),
    );
  });

  testWidgets('web link mode at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: InMemoryApiKeyStore(),
      mode: WebLookupMode.link,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_link_320x568_scale1.6.png'),
    );
  });

  testWidgets('web empty state at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport()
      ..enqueue('api.tavily.com', tavilySearch(<Map<String, Object?>>[]));
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: configuredKeys(),
      transport: transport,
    );
    // The action sits below the first screen at this text scale.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_empty_320x568_scale1.6.png'),
    );
  });

  testWidgets('settings web keys at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await library(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: InMemoryApiKeyStore(
          initial: <WebKeyProvider, String>{
            WebKeyProvider.tavily: 'tvly-synthetic',
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-web-key-note')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_web_keys_390x844.png'),
    );
  });

  testWidgets('web results at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(
            url: 'https://www.bol.com/nl/nl/p/matrix/1002004013068310',
            title: 'Matrix',
          ),
        ]),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://www.bol.com/nl/nl/p/matrix/1002004013068310',
        body: productHtml(
          title: 'Matrix 4 Film Collection',
          code: kMatrix,
          brand: 'Warner Bros.',
          released: '1999-06-17',
        ),
      );
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: configuredKeys(),
      transport: transport,
      pages: pages,
    );
    // The action sits below the fold at this text scale.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('web-search')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_results_320x568_scale1.6.png'),
    );
  });

  testWidgets('settings web keys at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await library(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: InMemoryApiKeyStore(
          initial: <WebKeyProvider, String>{
            WebKeyProvider.tavily: 'tvly-synthetic',
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-web-key-note')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_web_keys_320x568_scale1.6.png'),
    );
  });

  testWidgets('web candidate card at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(
            url: 'https://www.bol.com/nl/nl/p/matrix/1002004013068310',
            title: 'Matrix',
          ),
        ]),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://www.bol.com/nl/nl/p/matrix/1002004013068310',
        body: productHtml(
          title: 'Matrix 4 Film Collection',
          code: kMatrix,
          brand: 'Warner Bros.',
          released: '1999-06-17',
        ),
      );
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: configuredKeys(),
      transport: transport,
      pages: pages,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('web-search')));
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
      matchesGoldenFile('goldens/web_candidate_320x568_scale1.6.png'),
    );
  });

  testWidgets('web repeated failures at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    // Two failures with the same kind *and* label plus one with a different
    // label: the exact shape that used to throw "Duplicate keys found".
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/blocked-a', title: 'A'),
          tavilyResult(url: 'https://shop.example/blocked-b', title: 'B'),
          tavilyResult(url: 'https://other.example/blocked-c', title: 'C'),
        ]),
      );
    final pages = FakePageFetcher()
      ..page('https://shop.example/blocked-a', statusCode: 403, body: 'no')
      ..page('https://shop.example/blocked-b', statusCode: 403, body: 'no')
      ..page('https://other.example/blocked-c', statusCode: 403, body: 'no');
    await pumpWeb(
      tester,
      repository: InMemoryMediaRepository(),
      keys: configuredKeys(),
      transport: transport,
      pages: pages,
    );
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();
    // Scroll the retrieval log into view so the repeated rows are evidence.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_repeated_failures_390x844.png'),
    );
  });
}
