import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/web/address_policy.dart';
import 'package:lyberry/services/web/page_fetcher.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late SafePageFetcher fetcher;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    // The test seam allows the loopback http server; every other rule (hosts,
    // ports, private addresses, redirect validation) still applies.
    fetcher = SafePageFetcher(allowInsecureTestUris: true);
  });

  tearDown(() async {
    fetcher.close();
    await server.close(force: true);
  });

  Future<void> respond(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    unawaited(() async {
      await for (final request in server) {
        await handler(request);
      }
    }());
  }

  test('fetches a page and reports its status and content type', () async {
    await respond((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body>hello</body></html>');
      await request.response.close();
    });

    final page = await fetcher.fetch(
      base.resolve('/product'),
      timeout: const Duration(seconds: 5),
    );
    expect(page.statusCode, 200);
    expect(page.isSuccess, isTrue);
    expect(page.isTextual, isTrue);
    expect(page.text, contains('hello'));
  });

  test('follows one validated redirect hop', () async {
    await respond((request) async {
      if (request.uri.path == '/a') {
        request.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, '/b');
      } else {
        request.response
          ..statusCode = 200
          ..write('arrived');
      }
      await request.response.close();
    });

    final page = await fetcher.fetch(
      base.resolve('/a'),
      timeout: const Duration(seconds: 5),
      maxBytes: 1024,
    );
    expect(page.statusCode, 200);
    expect(page.text, 'arrived');
    expect(page.uri.path, '/b');
    expect(page.redirectedFrom?.path, '/a');
  });

  test('rejects a redirect that leaves the public HTTPS policy', () async {
    await respond((request) async {
      request.response
        ..statusCode = 302
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://localhost:${server.port}/private',
        );
      await request.response.close();
    });

    await expectLater(
      fetcher.fetch(base.resolve('/a'), timeout: const Duration(seconds: 5)),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.blocked,
        ),
      ),
    );
  });

  test('never follows a redirect beyond the hop budget', () async {
    var hops = 0;
    await respond((request) async {
      hops++;
      request.response
        ..statusCode = 302
        ..headers.set(HttpHeaders.locationHeader, '/next');
      await request.response.close();
    });

    await expectLater(
      fetcher.fetch(
        base.resolve('/start'),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.blocked,
        ),
      ),
    );
    expect(hops, lessThanOrEqualTo(3));
  });

  test('stops reading past the byte cap', () async {
    await respond((request) async {
      request.response.statusCode = 200;
      request.response.add(List<int>.filled(64 * 1024, 0x61));
      await request.response.close();
    });

    await expectLater(
      fetcher.fetch(
        base.resolve('/big'),
        timeout: const Duration(seconds: 5),
        maxBytes: 1024,
      ),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.noContent,
        ),
      ),
    );
  });

  test('honours the overall deadline', () async {
    await respond((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      request.response.statusCode = 200;
      await request.response.close();
    });

    await expectLater(
      fetcher.fetch(
        base.resolve('/slow'),
        timeout: const Duration(milliseconds: 80),
      ),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.timeout,
        ),
      ),
    );
  });

  test('reports cancellation before any connection is made', () async {
    await expectLater(
      fetcher.fetch(
        base.resolve('/never'),
        timeout: const Duration(seconds: 5),
        isCancelled: () => true,
      ),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.cancelled,
        ),
      ),
    );
  });

  test('refuses private DNS answers even for an allowed looking URL', () async {
    final pinned = SafePageFetcher(
      allowInsecureTestUris: true,
      resolver: (host, port) async => <InternetAddress>[
        InternetAddress('10.0.0.7'),
      ],
    );
    addTearDown(pinned.close);
    await expectLater(
      pinned.fetch(
        Uri.parse('https://shop.example/item'),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.blocked,
        ),
      ),
    );
  });

  test('refuses an IPv4-mapped private answer', () async {
    final pinned = SafePageFetcher(
      allowInsecureTestUris: true,
      resolver: (host, port) async => <InternetAddress>[
        InternetAddress('::ffff:127.0.0.1'),
      ],
    );
    addTearDown(pinned.close);
    expect(
      AddressPolicy.isPublicAddress(InternetAddress('::ffff:127.0.0.1')),
      isFalse,
    );
    await expectLater(
      pinned.fetch(
        Uri.parse('https://shop.example/item'),
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<WebLookupException>()),
    );
  });

  test('maps a refused page to a non-success response', () async {
    await respond((request) async {
      request.response.statusCode = 403;
      await request.response.close();
    });

    final page = await fetcher.fetch(
      base.resolve('/forbidden'),
      timeout: const Duration(seconds: 5),
    );
    expect(page.statusCode, 403);
    expect(page.isSuccess, isFalse);
  });

  test('does not send credentials or cookies to pages', () async {
    late Map<String, String> seen;
    await respond((request) async {
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      seen = headers;
      request.response
        ..statusCode = 200
        ..write(utf8.encode('ok'));
      await request.response.close();
    });

    await fetcher.fetch(
      base.resolve('/headers'),
      timeout: const Duration(seconds: 5),
    );
    expect(seen.keys, isNot(contains('authorization')));
    expect(seen.keys, isNot(contains('cookie')));
    expect(seen['accept'], contains('text/html'));
  });
}
