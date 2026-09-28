import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/web/web_lookup_service.dart';

import '../../support/fake_web.dart';

const String kMatrix = '5051888100639';
const String kWiiUpc = '045496367619';
const String kWiiEan = '0045496367619';

WebLookupService service({
  required InMemoryApiKeyStore keys,
  required FakeApiTransport transport,
  required FakePageFetcher pages,
  Duration budget = const Duration(seconds: 5),
}) => WebLookupService(
  keys: keys,
  transport: transport,
  pages: pages,
  budget: budget,
  pageTimeout: const Duration(seconds: 2),
);

InMemoryApiKeyStore keysWith({bool tavily = true, bool deepseek = true}) =>
    InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        if (tavily) WebKeyProvider.tavily: 'tvly-synthetic',
        if (deepseek) WebKeyProvider.deepseek: 'sk-synthetic',
      },
    );

LookupQuery query(String code, {MediaType? medium}) => LookupQuery(
  identifier: IdentifierNormalizer.normalize(code),
  mediumHint: medium,
);

void main() {
  test('search without a Tavily key never touches the network', () async {
    final keys = keysWith(tavily: false);
    final transport = FakeApiTransport();
    final pages = FakePageFetcher();
    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    expect(outcome.candidates, isEmpty);
    expect(outcome.failures.single.kind, WebFailureKind.missingKey);
    expect(outcome.failures.single.label, 'Tavily');
    expect(transport.calls, 0);
    expect(pages.fetched, isEmpty);
  });

  test('structured Product data answers without a model call', () async {
    final keys = keysWith();
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
          released: '2008-09-26',
          description: 'Barcode $kMatrix on the page.',
          image: 'https://m.media-amazon.com/images/I/matrix.jpg',
        ),
      );

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    expect(outcome.candidates, hasLength(1));
    final candidate = outcome.candidates.single;
    expect(candidate.origin, WebCandidateOrigin.structured);
    expect(candidate.candidate.providerId, 'web_structured');
    expect(candidate.candidate.matchKind, MatchKind.exact);
    expect(candidate.candidate.title, 'Matrix');
    expect(candidate.candidate.creator, 'Warner Bros.');
    expect(candidate.candidate.year, 2008);
    expect(
      candidate.candidate.externalId,
      'https://shop.example/matrix#$kMatrix',
    );
    expect(candidate.candidate.sourceUrl, 'https://shop.example/matrix');
    expect(candidate.domain, 'shop.example');
    expect(
      candidate.candidate.coverUrl,
      'https://m.media-amazon.com/images/I/matrix.jpg',
    );
    // Exactly one paid call: search. Structured data skips the model.
    expect(transport.calls, 1);
    expect(transport.requestAt(0).uri.host, 'api.tavily.com');
  });

  test(
    'searches the canonical code for a UPC while keeping the scan',
    () async {
      final keys = keysWith();
      final transport = FakeApiTransport()
        ..enqueue(
          'api.tavily.com',
          tavilySearch(<Map<String, Object?>>[
            tavilyResult(url: 'https://shop.example/wii', title: 'Wii Sports'),
          ]),
        );
      final pages = FakePageFetcher()
        ..page(
          'https://shop.example/wii',
          body: productHtml(title: 'Wii Sports Resort', code: kWiiEan),
        );

      final outcome = await service(
        keys: keys,
        transport: transport,
        pages: pages,
      ).search(query(kWiiUpc, medium: MediaType.game));

      expect(transport.requestAt(0).body['query'], '"$kWiiEan" Game');
      expect(outcome.candidates, hasLength(1));
      expect(outcome.candidates.single.candidate.medium, MediaType.game);
      // The trusted identity keeps the canonical key for the scanned UPC too.
      expect(
        outcome.candidates.single.candidate.externalId,
        endsWith('#$kWiiEan'),
      );
    },
  );

  test('never calls the model when no page shows the code', () async {
    final keys = keysWith();
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/other', title: 'Other'),
        ]),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/other',
        body:
            '<html><body>An unrelated page about something else.</body></html>',
      );

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    expect(outcome.candidates, isEmpty);
    expect(
      outcome.failures.map((failure) => failure.kind),
      contains(WebFailureKind.noContent),
    );
    expect(transport.calls, 1);
  });

  test('uses Tavily raw content when a direct fetch is refused', () async {
    final keys = keysWith();
    final html = productHtml(title: 'Matrix', code: kMatrix);
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(
            url: 'https://shop.example/blocked',
            title: 'Matrix',
            rawContent: html,
          ),
        ]),
      );
    final pages = FakePageFetcher()
      ..failure(
        'https://shop.example/blocked',
        const WebLookupException(
          WebFailureKind.blocked,
          'That page refused to be read.',
        ),
      );

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    expect(outcome.candidates, hasLength(1));
    expect(outcome.candidates.single.origin, WebCandidateOrigin.structured);
    expect(
      outcome.failures.map((failure) => failure.kind),
      contains(WebFailureKind.blocked),
    );
    expect(transport.calls, 1);
  });

  test('falls back to Tavily Extract and then the model', () async {
    final keys = keysWith();
    final pageText = 'Matrix Blu-ray. Barcode $kMatrix. Studio: Warner Bros.';
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/blocked', title: 'Matrix'),
        ]),
      )
      ..enqueue(
        'api.tavily.com',
        FakeApiCall(
          statusCode: 200,
          json: <String, Object?>{
            'results': <Map<String, Object?>>[
              <String, Object?>{
                'url': 'https://shop.example/blocked',
                'raw_content': pageText,
              },
              <String, Object?>{
                'url': 'https://attacker.example/inject',
                'raw_content': 'Unrelated text',
              },
            ],
          },
        ),
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
              'medium': 'bluray',
              'creator': 'Warner Bros.',
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
      ..failure(
        'https://shop.example/blocked',
        const WebLookupException(
          WebFailureKind.blocked,
          'That page refused to be read.',
        ),
      );

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    expect(outcome.candidates, hasLength(1));
    final candidate = outcome.candidates.single;
    expect(candidate.origin, WebCandidateOrigin.ai);
    expect(candidate.candidate.providerId, 'web_deepseek');
    expect(candidate.candidate.matchKind, MatchKind.possible);
    expect(candidate.candidate.medium, MediaType.bluray);
    expect(candidate.candidate.sourceUrl, 'https://shop.example/blocked');
    expect(outcome.usedExtraction, isTrue);
    // Search, extract and one model call: the unrelated extract URL never
    // became a source.
    expect(transport.calls, 3);
    expect(outcome.pages, hasLength(1));
    expect(outcome.pages.single.url, 'https://shop.example/blocked');
  });

  test('keeps a usable page when another retrieval fails', () async {
    final keys = keysWith();
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/good', title: 'Matrix'),
          tavilyResult(url: 'https://shop.example/bad', title: 'Bad'),
        ]),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/good',
        body: productHtml(title: 'Matrix', code: kMatrix),
      )
      ..page('https://shop.example/bad', statusCode: 503, body: 'nope');

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    expect(outcome.candidates, hasLength(1));
    expect(outcome.failures, isNotEmpty);
    expect(outcome.failures.first.message, isNot(contains('nope')));
  });

  test(
    'a malformed AI answer is a failure, not a silent empty result',
    () async {
      final keys = keysWith();
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
                  'message': <String, Object?>{'content': '{"broken":'},
                },
              ],
            },
          ),
        );
      final pages = FakePageFetcher()
        ..page(
          'https://shop.example/matrix',
          body: '<html><body><p>$pageText</p></body></html>',
        );

      final outcome = await service(
        keys: keys,
        transport: transport,
        pages: pages,
      ).search(query(kMatrix));

      expect(outcome.candidates, isEmpty);
      expect(outcome.failures.single.kind, WebFailureKind.malformed);
      expect(outcome.failures.single.label, 'DeepSeek');
    },
  );

  test('cancellation stops before any paid call', () async {
    final keys = keysWith();
    final transport = FakeApiTransport();
    final pages = FakePageFetcher();
    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix), isCancelled: () => true);

    expect(outcome.failures.single.kind, WebFailureKind.cancelled);
    expect(transport.calls, 0);
    expect(pages.fetched, isEmpty);
  });

  test('duplicate taps cannot pay twice', () async {
    final keys = keysWith();
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        FakeApiCall(
          statusCode: 200,
          json: <String, Object?>{'results': <Object?>[]},
          delay: const Duration(milliseconds: 150),
        ),
      );
    final pages = FakePageFetcher();
    final lookup = service(keys: keys, transport: transport, pages: pages);

    final first = lookup.search(query(kMatrix));
    final second = await lookup.search(query(kMatrix));
    expect(second.failures.single.kind, WebFailureKind.cancelled);
    await first;
    expect(transport.calls, 1);
  });

  test('import link reads structured data with no keys at all', () async {
    final keys = keysWith(tavily: false, deepseek: false);
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/product',
        body: productHtml(title: 'Matrix', code: kMatrix),
      );
    final outcome =
        await service(
          keys: keys,
          transport: FakeApiTransport(),
          pages: pages,
        ).importLink(
          identifier: IdentifierNormalizer.normalize(kMatrix),
          url: Uri.parse('https://shop.example/product'),
        );

    expect(outcome.candidates, hasLength(1));
    expect(outcome.candidates.single.origin, WebCandidateOrigin.structured);
  });

  test('import link without structured data asks for the model key', () async {
    final keys = keysWith(tavily: false, deepseek: false);
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/product',
        body: '<html><body><p>Matrix. Barcode $kMatrix.</p></body></html>',
      );
    final outcome =
        await service(
          keys: keys,
          transport: FakeApiTransport(),
          pages: pages,
        ).importLink(
          identifier: IdentifierNormalizer.normalize(kMatrix),
          url: Uri.parse('https://shop.example/product'),
        );

    expect(outcome.candidates, isEmpty);
    expect(outcome.failures.single.kind, WebFailureKind.missingKey);
    expect(outcome.failures.single.label, 'DeepSeek');
  });

  test('import link refuses private and non-https destinations', () async {
    final keys = keysWith();
    final pages = FakePageFetcher();
    final lookup = service(
      keys: keys,
      transport: FakeApiTransport(),
      pages: pages,
    );

    for (final url in <String>[
      'http://shop.example/product',
      'https://127.0.0.1/product',
      'https://localhost/product',
      'https://10.1.2.3/product',
    ]) {
      final outcome = await lookup.importLink(
        identifier: IdentifierNormalizer.normalize(kMatrix),
        url: Uri.parse(url),
      );
      expect(outcome.candidates, isEmpty, reason: url);
      expect(outcome.failures.single.kind, WebFailureKind.blocked, reason: url);
    }
    expect(pages.fetched, isEmpty);
  });

  test('a conflicting structured format beats the medium hint', () async {
    final keys = keysWith();
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/book'),
        ]),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/book',
        body: productHtml(
          title: 'A book',
          code: kMatrix,
        ).replaceFirst('"@type":"Product"', '"@type":["Product","Book"]'),
      );

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix, medium: MediaType.dvd));

    expect(outcome.candidates.single.candidate.medium, MediaType.book);
  });

  test('the search query is minimized to the code and hint', () {
    final text = WebLookupService.searchQuery(
      query(kMatrix, medium: MediaType.bluray),
    );
    expect(text, '"$kMatrix" Blu-ray');
    expect(WebLookupService.searchQuery(query(kMatrix)), '"$kMatrix"');
  });

  test('evidence sent to the model is bounded and quoted', () async {
    final keys = keysWith();
    final long = 'filler ' * 20000;
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        tavilySearch(<Map<String, Object?>>[
          tavilyResult(url: 'https://shop.example/long'),
        ]),
      )
      ..enqueue(
        'api.deepseek.com',
        deepSeekAnswer(<String, Object?>{
          'schemaVersion': 1,
          'barcode': kMatrix,
          'candidates': <Object?>[],
        }),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/long',
        body: '<html><body><p>$long Barcode $kMatrix $long</p></body></html>',
      );

    await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    final messages = transport.requestAt(1).body['messages']! as List<Object?>;
    final user = (messages.last! as Map<String, Object?>)['content']! as String;
    expect(user.length, lessThanOrEqualTo(36 * 1024 + 512));
    expect(user, contains(kMatrix));
    expect(
      jsonEncode(transport.requestAt(1).body),
      isNot(contains('sk-synthetic')),
    );
  });

  test('the single-flight lock is held until extraction finishes', () async {
    final keys = keysWith();
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
                    'candidates': <Object?>[],
                  }),
                },
              },
            ],
          },
          delay: const Duration(milliseconds: 250),
        ),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/matrix',
        body: '<html><body><p>$pageText</p></body></html>',
      );
    final lookup = service(keys: keys, transport: transport, pages: pages);

    final first = lookup.search(query(kMatrix));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // The model call is still in flight, so the lock must still be held.
    final second = await lookup.search(query(kMatrix));
    expect(second.failures.single.kind, WebFailureKind.cancelled);
    expect(second.failures.single.message, contains('already running'));

    await first;
    expect(transport.calls, 2);
  });

  test('cancelling during extraction stops the pipeline', () async {
    final keys = keysWith();
    final pageText = 'Matrix Blu-ray. Barcode $kMatrix.';
    var cancelled = false;
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
          delay: const Duration(milliseconds: 200),
        ),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/matrix',
        body: '<html><body><p>$pageText</p></body></html>',
      );
    final lookup = service(keys: keys, transport: transport, pages: pages);

    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 80),
        () => cancelled = true,
      ),
    );
    final outcome = await lookup.search(
      query(kMatrix),
      isCancelled: () => cancelled,
    );

    expect(outcome.candidates, isEmpty);
    expect(outcome.failures.single.kind, WebFailureKind.cancelled);
  });

  test('a cancelled link fetch never runs Tavily Extract', () async {
    final keys = keysWith();
    final transport = FakeApiTransport();
    var cancelled = false;
    final pages = FakePageFetcher();
    pages.onFetch = (uri) => cancelled = true;
    pages.failure(
      'https://shop.example/product',
      const WebLookupException(
        WebFailureKind.cancelled,
        'The page request was cancelled.',
      ),
    );

    final outcome =
        await service(
          keys: keys,
          transport: transport,
          pages: pages,
        ).importLink(
          identifier: IdentifierNormalizer.normalize(kMatrix),
          url: Uri.parse('https://shop.example/product'),
          isCancelled: () => cancelled,
        );

    expect(outcome.candidates, isEmpty);
    expect(outcome.failures.single.kind, WebFailureKind.cancelled);
    // No search, no extract: the paid stages never started.
    expect(transport.calls, 0);
  });

  test(
    'cancellation during a slow key read stops before the next stage',
    () async {
      final keys = keysWith();
      keys.readDelay = const Duration(milliseconds: 120);
      final transport = FakeApiTransport();
      final pages = FakePageFetcher();
      var cancelled = false;
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 40),
          () => cancelled = true,
        ),
      );

      final outcome = await service(
        keys: keys,
        transport: transport,
        pages: pages,
      ).search(query(kMatrix), isCancelled: () => cancelled);

      expect(outcome.failures.single.kind, WebFailureKind.cancelled);
      expect(transport.calls, 0);
      expect(pages.fetched, isEmpty);
    },
  );

  test('an exhausted budget is a timeout, not a cancellation', () async {
    final keys = keysWith();
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        FakeApiCall(
          statusCode: 200,
          json: <String, Object?>{'results': <Object?>[]},
          delay: const Duration(milliseconds: 400),
        ),
      );
    final pages = FakePageFetcher();

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
      budget: const Duration(milliseconds: 120),
    ).search(query(kMatrix));

    expect(outcome.candidates, isEmpty);
    expect(outcome.failures.last.kind, WebFailureKind.timeout);
    expect(
      outcome.failures.map((failure) => failure.kind),
      isNot(contains(WebFailureKind.cancelled)),
    );
    expect(pages.fetched, isEmpty);
  });

  test('separator-printed codes gate and validate', () async {
    final keys = keysWith();
    final spaced = '505 1888 100639';
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
              'medium': 'bluray',
              'creator': null,
              'year': null,
              'publisher': null,
              'description': null,
              'platform': null,
              'barcodeQuote': 'Codice $spaced',
              'titleQuote': 'Matrix',
            },
          ],
        }),
      );
    final pages = FakePageFetcher()
      ..page(
        'https://shop.example/matrix',
        body: '<html><body><h1>Matrix</h1><p>Codice $spaced.</p></body></html>',
      );

    final outcome = await service(
      keys: keys,
      transport: transport,
      pages: pages,
    ).search(query(kMatrix));

    expect(outcome.candidates, hasLength(1));
    expect(outcome.candidates.single.candidate.matchKind, MatchKind.possible);
  });
}
