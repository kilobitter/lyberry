import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/api_transport.dart';

void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  IoApiTransport transport({Set<String>? hosts}) => IoApiTransport(
    allowedHosts: hosts ?? const <String>{'127.0.0.1'},
    allowInsecureTestUris: true,
  );

  Future<void> serve(Future<void> Function(HttpRequest request) handler) async {
    unawaited(() async {
      await for (final request in server) {
        await handler(request);
      }
    }());
  }

  test('posts JSON with the bearer token and returns the answer', () async {
    late Map<String, String> headers;
    late String body;
    await serve((request) async {
      headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{'ok': true}));
      await request.response.close();
    });

    final response = await transport().post(
      ApiRequest(
        uri: base.resolve('/search'),
        bearerToken: 'tvly-synthetic',
        body: <String, Object?>{'query': '"5051888100639"'},
      ),
      timeout: const Duration(seconds: 5),
      maxBytes: 64 * 1024,
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), <String, Object?>{'ok': true});
    expect(headers['authorization'], 'Bearer tvly-synthetic');
    expect(headers['content-type'], contains('application/json'));
    expect(body, contains('5051888100639'));
  });

  test('does not follow redirects', () async {
    var followed = false;
    await serve((request) async {
      if (request.uri.path == '/target') {
        followed = true;
        request.response
          ..statusCode = 200
          ..write('should not be reached');
      } else {
        request.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, 'https://example.com/x');
      }
      await request.response.close();
    });

    final response = await transport().post(
      ApiRequest(uri: base.resolve('/start'), body: const <String, Object?>{}),
      timeout: const Duration(seconds: 5),
      maxBytes: 4096,
    );
    expect(response.statusCode, 302);
    expect(followed, isFalse);
  });

  test('stops reading past the byte cap', () async {
    await serve((request) async {
      request.response.statusCode = 200;
      request.response.add(List<int>.filled(64 * 1024, 0x61));
      await request.response.close();
    });

    await expectLater(
      transport().post(
        ApiRequest(uri: base.resolve('/big'), body: const <String, Object?>{}),
        timeout: const Duration(seconds: 5),
        maxBytes: 1024,
      ),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.malformed,
        ),
      ),
    );
  });

  test('honours the whole-request deadline', () async {
    await serve((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      request.response.statusCode = 200;
      await request.response.close();
    });

    await expectLater(
      transport().post(
        ApiRequest(uri: base.resolve('/slow'), body: const <String, Object?>{}),
        timeout: const Duration(milliseconds: 80),
        maxBytes: 4096,
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

  test('maps a refused connection to a sanitized network failure', () async {
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close(force: true);

    WebLookupException? error;
    try {
      await transport().post(
        ApiRequest(
          uri: Uri.parse('http://127.0.0.1:$deadPort/search'),
          bearerToken: 'tvly-should-not-appear',
          body: const <String, Object?>{'query': 'secret-query'},
        ),
        timeout: const Duration(seconds: 3),
        maxBytes: 4096,
      );
    } on WebLookupException catch (caught) {
      error = caught;
    }

    expect(error, isNotNull);
    expect(error!.kind, WebFailureKind.network);
    expect(error.message, isNot(contains('tvly-should-not-appear')));
    expect(error.message, isNot(contains('secret-query')));
    expect(error.message, isNot(contains('127.0.0.1')));
  });

  test('refuses a host outside the allowlist without any request', () async {
    await expectLater(
      transport().post(
        ApiRequest(
          uri: Uri.parse('https://api.tavily.com/search'),
          bearerToken: 'tvly-synthetic',
          body: const <String, Object?>{},
        ),
        timeout: const Duration(seconds: 3),
        maxBytes: 4096,
      ),
      throwsA(
        isA<WebLookupException>().having(
          (error) => error.kind,
          'kind',
          WebFailureKind.unavailable,
        ),
      ),
    );
  });

  test(
    'maps API errors without leaking the key or the response body',
    () async {
      for (final (status, kind) in <(int, WebFailureKind)>[
        (401, WebFailureKind.invalidKey),
        (402, WebFailureKind.quota),
        (429, WebFailureKind.quota),
        (503, WebFailureKind.unavailable),
      ]) {
        final testServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final testBase = Uri.parse('http://127.0.0.1:${testServer.port}');
        unawaited(() async {
          await for (final request in testServer) {
            request.response
              ..statusCode = status
              ..write('body-with-tvly-synthetic-and-other-noise');
            await request.response.close();
          }
        }());

        try {
          final response = await transport().post(
            ApiRequest(
              uri: testBase.resolve('/x'),
              bearerToken: 'tvly-synthetic',
              body: const <String, Object?>{},
            ),
            timeout: const Duration(seconds: 3),
            maxBytes: 4096,
          );
          expect(response.statusCode, status);
          // The transport never turns a body into an error message; the shared
          // mapper is the sanitized layer every client uses.
          final error = apiStatusException(
            response.statusCode,
            WebLookupStage.search,
          );
          expect(error.kind, kind);
          expect(error.message, isNot(contains('tvly-synthetic')));
          expect(error.message, isNot(contains('other-noise')));
          expect(response.body, contains('other-noise'));
        } finally {
          await testServer.close(force: true);
        }
      }
    },
  );
}
