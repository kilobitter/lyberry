import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/web/web_lookup_service.dart';
import 'package:lyberry/state/web_lookup_controller.dart';

import '../support/fake_web.dart';

const String kMatrix = '5051888100639';
const String kPageUrl = 'https://shop.example/matrix';

void main() {
  test('a cancelled run stays cancelled through retry and dispose', () async {
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
        WebKeyProvider.deepseek: 'sk-synthetic',
      },
    );
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        FakeApiCall(
          statusCode: 200,
          json: <String, Object?>{
            'results': <Object?>[
              <String, Object?>{'url': kPageUrl, 'title': 'Matrix'},
            ],
          },
          delay: const Duration(milliseconds: 200),
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
        kPageUrl,
        body:
            '<html><body><p>Matrix Blu-ray. Barcode $kMatrix.</p></body></html>',
      );
    final service = WebLookupService(
      keys: keys,
      transport: transport,
      pages: pages,
      budget: const Duration(seconds: 5),
    );
    final controller = WebLookupController(
      service: service,
      identifier: IdentifierNormalizer.normalize(kMatrix),
    );

    // Run A (generation 1) is inside the Tavily search.
    final runA = controller.runSearch();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    // Cancel A, immediately start B (generation 2, refused by the pipeline
    // lock), then dispose while A's request is still pending.
    controller.cancel();
    final runB = controller.runSearch();
    await runB;
    controller.dispose();

    await runA;
    // Give any late continuation the chance to start the model call.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // Only the search was made: the cancelled run never reached a later paid
    // stage, and dispose did not revive it.
    expect(transport.calls, 1);
    expect(transport.requestAt(0).uri.host, 'api.tavily.com');
    expect(pages.fetched, isEmpty);
    expect(
      jsonEncode(transport.requestAt(0).body),
      isNot(contains('sk-synthetic')),
    );
  });

  test('a fresh run after a cancel is not treated as cancelled', () async {
    final keys = InMemoryApiKeyStore(
      initial: <WebKeyProvider, String>{
        WebKeyProvider.tavily: 'tvly-synthetic',
      },
    );
    final transport = FakeApiTransport()
      ..enqueue(
        'api.tavily.com',
        FakeApiCall(
          statusCode: 200,
          json: <String, Object?>{'results': <Object?>[]},
          delay: const Duration(milliseconds: 150),
        ),
      )
      ..enqueue('api.tavily.com', tavilySearch(<Map<String, Object?>>[]));
    final pages = FakePageFetcher();
    final service = WebLookupService(
      keys: keys,
      transport: transport,
      pages: pages,
      budget: const Duration(seconds: 5),
    );
    final controller = WebLookupController(
      service: service,
      identifier: IdentifierNormalizer.normalize(kMatrix),
    );
    addTearDown(controller.dispose);

    final firstRun = controller.runSearch();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    controller.cancel();
    await firstRun;

    // The second run is a new operation and must reach the provider.
    await controller.runSearch();
    expect(transport.calls, 2);
    expect(controller.status, WebLookupStatus.failed);
    expect(
      controller.failures.map((failure) => failure.kind),
      contains(WebFailureKind.noContent),
    );
    expect(
      controller.failures.map((failure) => failure.kind),
      isNot(contains(WebFailureKind.cancelled)),
    );
  });
}
