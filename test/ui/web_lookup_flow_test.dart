import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/state/web_lookup_controller.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/screens/settings_screen.dart';
import 'package:lyberry/ui/screens/web_lookup_screen.dart';

import '../support/fake_snapshot_io.dart';
import '../support/fake_web.dart';
import '../support/in_memory_repository.dart';
import '../support/stub_provider.dart';
import '../support/test_support.dart';

const String kMatrix = '5051888100639';

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

  /// Pushes the web lookup screen and records what it pops.
  Future<LookupChoice?> Function() pushWeb(
    WidgetTester tester, {
    MediaType? mediumHint,
    WebLookupMode mode = WebLookupMode.search,
  }) {
    LookupChoice? popped;
    var settled = false;
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator
          .push<LookupChoice>(
            MaterialPageRoute<LookupChoice>(
              builder: (_) => WebLookupScreen(
                identifier: IdentifierNormalizer.normalize(kMatrix),
                mediumHint: mediumHint,
                initialMode: mode,
              ),
            ),
          )
          .then((value) {
            popped = value;
            settled = true;
          }),
    );
    return () async {
      await tester.pumpAndSettle();
      return settled ? popped : null;
    };
  }

  testWidgets('opening the screen makes no paid request', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport();
    final pages = FakePageFetcher();
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
        WebKeyProvider.deepseek: 'sk-synthetic',
      },
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport,
        pages: pages,
      ),
    );
    await tester.pumpAndSettle();

    pushWeb(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('web-code')), findsOneWidget);
    expect(find.byKey(const Key('web-idle')), findsOneWidget);
    expect(transport.calls, 0);
    expect(pages.fetched, isEmpty);
    expect(keys.writes, 0);
  });

  testWidgets('a missing key explains setup and keeps the code', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport();
    final keys = InMemoryApiKeyStore();
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport,
      ),
    );
    await tester.pumpAndSettle();
    pushWeb(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('web-missing-key')), findsOneWidget);
    expect(find.textContaining('Tavily'), findsWidgets);
    expect(transport.calls, 0);

    // Saving a key never triggers a lookup, and coming back keeps the code.
    await tester.tap(find.byKey(const Key('web-open-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsRouteScreen), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('settings-tavily-field')),
      'tvly-synthetic-ui',
    );
    await tester.tap(find.byKey(const Key('settings-tavily-save')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('settings-tavily-status'))).data,
      'Saved',
    );
    expect(keys.peek(WebKeyProvider.tavily), 'tvly-synthetic-ui');
    expect(transport.calls, 0);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web-code')), findsOneWidget);
    expect(find.text(kMatrix), findsOneWidget);
    expect(transport.calls, 0);

    // Removing it again is surfaced too, and still runs nothing.
    await tester.tap(find.byKey(const Key('web-open-settings')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('settings-tavily-status'))).data,
      'Saved',
    );
    await tester.ensureVisible(find.byKey(const Key('settings-tavily-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-tavily-remove')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('settings-tavily-status'))).data,
      'Not configured',
    );
    expect(keys.peek(WebKeyProvider.tavily), isNull);
    expect(transport.calls, 0);
  });

  testWidgets('explicit search shows reviewed results and saves nothing', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/matrix', title: 'Matrix'),
        ]),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/matrix',
        body: productHtml(
          title: 'Matrix',
          code: kMatrix,
          brand: 'Warner Bros.',
        ),
      );
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
        WebKeyProvider.deepseek: 'sk-synthetic',
      },
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport,
        pages: pages,
      ),
    );
    await tester.pumpAndSettle();
    // A medium hint is supplied, so the structured result can be used directly
    // without the "which medium" question.
    final result = pushWeb(tester, mediumHint: MediaType.bluray);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();

    expect(find.text('Matrix'), findsWidgets);
    expect(find.text('EXACT CODE MATCH'), findsOneWidget);
    expect(find.textContaining('STRUCTURED DATA'), findsWidgets);
    expect(find.textContaining('shop.example'), findsWidgets);
    expect(await repository.countItems(), 0);
    expect(transport.calls, 1);

    await tester.tap(find.text('Use this'));
    final choice = await result();
    expect(choice, isA<UseCandidate>());
    final candidate = (choice! as UseCandidate).candidate;
    expect(candidate.title, 'Matrix');
    // The hint fills the missing format instead of a silent default.
    expect(candidate.medium, MediaType.bluray);
    expect(candidate.providerId, 'web_structured');
    expect(candidate.sourceUrl, 'https://shop.example/matrix');
    expect(await repository.countItems(), 0);
  });

  testWidgets('asks for the medium when the source does not say', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final pageText = 'Matrix Blu-ray. Barcode $kMatrix.';
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/matrix', title: 'Matrix'),
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
              'title': 'Matrix',
              'medium': null,
              'creator': null,
              'year': null,
              'publisher': null,
              'description': null,
              'platform': null,
              'barcodeQuote': 'Barcode $kMatrix',
              'titleQuote': 'Matrix Blu-ray',
            },
          ],
        }),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/matrix',
        body: '<html><body><p>$pageText</p></body></html>',
      );
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
        WebKeyProvider.deepseek: 'sk-synthetic',
      },
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport,
        pages: pages,
      ),
    );
    await tester.pumpAndSettle();
    final result = pushWeb(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();
    expect(find.text('POSSIBLE MATCH'), findsOneWidget);
    expect(find.textContaining('AI EXTRACTED'), findsWidgets);

    await tester.tap(find.text('Use this'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web-medium-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('web-choose-dvd')));
    final choice = await result();
    expect((choice! as UseCandidate).candidate.medium, MediaType.dvd);
  });

  testWidgets('cancel stops the run and ignores the late answer', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        FakeApiCall(
          statusCode: 200,
          json: <String, Object?>{
            'results': <Object?>[
              <String, Object?>{
                'url': 'https://shop.example/matrix',
                'title': 'Matrix',
              },
            ],
          },
          delay: const Duration(milliseconds: 400),
        ),
      );
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
      },
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport,
      ),
    );
    await tester.pumpAndSettle();
    pushWeb(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pump();
    expect(find.byKey(const Key('web-running')), findsOneWidget);

    await tester.tap(find.byKey(const Key('web-cancel')));
    await tester.pump();
    expect(find.byKey(const Key('web-empty')), findsOneWidget);
    expect(find.byKey(const Key('web-running')), findsNothing);

    // The late answer must not replace the cancelled state.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web-empty')), findsOneWidget);
    expect(find.text('Use this'), findsNothing);
  });

  testWidgets('a cancelled operation stays cancelled when the user taps again', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final pageText = 'Matrix Blu-ray. Barcode $kMatrix.';
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/matrix', title: 'Matrix'),
        ]),
      )
      ..enqueue(
        'api.deepseek.com',
        FakeApiCall(
          statusCode: 200,
          json: <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'finish_reason': 'stop',
                'message': <String, Object?>{
                  'content': jsonEncode(<String, Object?>{
                    'schemaVersion': 1,
                    'barcode': kMatrix,
                    'candidates': <Object?>[
                      <String, Object?>{
                        'sourceId': 's1',
                        'title': 'Matrix',
                        'medium': 'bluray',
                        'creator': null,
                        'year': null,
                        'publisher': null,
                        'description': null,
                        'platform': null,
                        'barcodeQuote': 'Barcode $kMatrix',
                        'titleQuote': 'Matrix Blu-ray',
                      },
                    ],
                  }),
                },
              },
            ],
          },
          delay: const Duration(milliseconds: 300),
        ),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/matrix',
        body: '<html><body><p>$pageText</p></body></html>',
      );
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
        WebKeyProvider.deepseek: 'sk-synthetic',
      },
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport,
        pages: pages,
      ),
    );
    await tester.pumpAndSettle();
    pushWeb(tester);
    await tester.pumpAndSettle();

    // Start, let the search finish and the model call begin, then cancel.
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const Key('web-running')), findsOneWidget);
    await tester.tap(find.byKey(const Key('web-cancel')));
    await tester.pump();
    expect(find.byKey(const Key('web-empty')), findsOneWidget);

    // A new tap while the cancelled pipeline is still unwinding must not revive
    // it: no candidate may appear afterwards.
    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('web-empty')), findsOneWidget);
    expect(find.text('Use this'), findsNothing);
    expect(find.textContaining('POSSIBLE MATCH'), findsNothing);
    // One search and one model call only: nothing extra was billed.
    expect(transport.calls, 2);
    expect(await repository.countItems(), 0);
  });

  testWidgets('manual fallback and link validation stay explicit', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final transport = FakeApiTransport();
    final pages = FakePageFetcher();
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        apiTransport: transport,
        pages: pages,
      ),
    );
    await tester.pumpAndSettle();

    // Link mode: a bad value is refused without any fetch.
    final result = pushWeb(tester, mode: WebLookupMode.link);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('web-link-field')),
      'not-a-url',
    );
    await tester.tap(find.byKey(const Key('web-read')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web-empty')), findsOneWidget);
    expect(find.textContaining('public https'), findsWidgets);
    expect(pages.fetched, isEmpty);
    expect(transport.calls, 0);

    // A private link is refused by policy as well.
    await tester.enterText(
      find.byKey(const Key('web-link-field')),
      'https://10.0.0.5/product',
    );
    await tester.tap(find.byKey(const Key('web-read')));
    await tester.pumpAndSettle();
    expect(pages.fetched, isEmpty);

    // The manual escape hatch is always one tap away.
    await tester.tap(find.byKey(const Key('web-manual')));
    final choice = await result();
    expect(choice, isA<AddManually>());
  });

  testWidgets('free lookup failures offer the web actions', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildLibrary();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(
        providers: <MetadataProvider>[
          StubMetadataProvider(
            failure: const ProviderException(
              LookupFailureKind.network,
              'You are offline.',
            ),
          ),
        ],
      ),
    );
    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();

    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => CandidatesScreen(
              query: LookupQuery(
                identifier: IdentifierNormalizer.normalize(kMatrix),
              ),
            ),
          ),
        );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('candidates-error')), findsOneWidget);
    expect(find.byKey(const Key('candidates-web-search')), findsOneWidget);
    expect(find.byKey(const Key('candidates-web-link')), findsOneWidget);

    await tester.tap(find.byKey(const Key('candidates-web-link')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('web-code')), findsOneWidget);
    expect(find.byKey(const Key('web-link-field')), findsOneWidget);
  });

  testWidgets('repeated failures keep every row without duplicate keys', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    // Three unusable pages: two on the same host (identical kind *and* label)
    // and one on another host (same kind, different label). Every row must
    // render, and none of the derived widget keys may collide.
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
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
        WebKeyProvider.deepseek: 'sk-synthetic',
      },
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        apiTransport: transport,
        pages: pages,
      ),
    );
    await tester.pumpAndSettle();
    pushWeb(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('web-search')));
    await tester.pumpAndSettle();

    // The original crash was "Duplicate keys found in Column" for
    // web-failure-blocked; nothing may be thrown now.
    expect(tester.takeException(), isNull);
    expect(find.textContaining('shop.example'), findsNWidgets(2));
    expect(find.textContaining('other.example'), findsOneWidget);
    expect(find.textContaining('Page blocked'), findsNWidgets(3));
    // The retry and manual escape hatches stay available.
    expect(find.byKey(const Key('web-empty-retry')), findsOneWidget);
    expect(find.byKey(const Key('web-manual')), findsOneWidget);
    expect(await repository.countItems(), 0);
  });

  testWidgets('backups never contain key values', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    await repository.createItem(
      sampleItem(id: '00000000-0000-4000-8000-000000000001'),
    );
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    final io = FakeSnapshotIo();
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-should-not-appear',
        WebKeyProvider.deepseek: 'sk-should-not-appear',
      },
    );
    await pumpApp(
      tester,
      controller,
      services: testServices(
        repository: repository,
        keys: keys,
        backup: BackupService(
          repository: repository,
          io: io,
          clock: FixedClock(kBaseTime),
          useIsolate: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-export')));
    await tester.pumpAndSettle();

    final exported = io.savedContents;
    expect(exported, isNotNull);
    expect(exported, isNot(contains('tvly-should-not-appear')));
    expect(exported, isNot(contains('sk-should-not-appear')));
    expect(jsonDecode(exported!), isA<Map<String, Object?>>());
  });

  testWidgets('state views never render the key the user typed', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final keys = InMemoryApiKeyStore();
    keys.writeFailure = const WebLookupException(
      WebFailureKind.unavailable,
      'Tavily key could not be saved on this device.',
      stage: WebLookupStage.keys,
    );
    final (controller, repository) = await buildLibrary();
    await pumpApp(
      tester,
      controller,
      services: testServices(repository: repository, keys: keys),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('settings-tavily-field')),
      'tvly-secret-should-not-render',
    );
    await tester.tap(find.byKey(const Key('settings-tavily-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be saved'), findsWidgets);
    // The input stays obscured and the value never reaches a rendered Text.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('settings-tavily-field')))
          .obscureText,
      isTrue,
    );
    final renderedText = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .join('|');
    expect(renderedText, isNot(contains('tvly-secret-should-not-render')));
    expect(
      tester.widget<Text>(find.byKey(const Key('settings-tavily-status'))).data,
      'Not configured',
    );
  });
}
