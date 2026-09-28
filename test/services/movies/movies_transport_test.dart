import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/movies/movies_transport.dart';

void main() {
  late HttpServer server;
  late MoviesEndpoint endpoint;
  late IoMoviesTransport transport;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = MoviesEndpoint(
      host: '127.0.0.1',
      pathTemplate: '/api/v1/lookup/:upc',
      codeLength: 12,
    );
    transport = IoMoviesTransport(
      allowedEndpoints: <String>{endpoint.key},
      allowInsecureTestUris: true,
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<void> serve(Future<void> Function(HttpRequest request) handler) async {
    unawaited(() async {
      await for (final request in server) {
        await handler(request);
      }
    }());
  }

  MoviesRequest requestFor(
    MoviesEndpoint target, {
    String code = '045496367619',
    Map<String, String> headers = const <String, String>{},
    String? path,
  }) => MoviesRequest(
    endpoint: target,
    uri: Uri.parse(
      'http://127.0.0.1:${server.port}${path ?? '/api/v1/lookup/$code'}',
    ),
    headers: headers,
  );

  test('sends an allowlisted request and returns the answer', () async {
    late Map<String, String> headers;
    await serve((request) async {
      headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<String, Object?>{'title': 'Full Metal Jacket'}));
      await request.response.close();
    });

    final response = await transport.get(
      requestFor(
        endpoint,
        headers: <String, String>{'x-api-key': 'upcmdb-synthetic'},
      ),
      timeout: const Duration(seconds: 5),
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), <String, Object?>{
      'title': 'Full Metal Jacket',
    });
    expect(headers['x-api-key'], 'upcmdb-synthetic');
    expect(headers['accept'], 'application/json');
  });

  test('rejects an endpoint that is not on the allowlist', () async {
    final other = MoviesEndpoint(
      host: '127.0.0.1',
      pathTemplate: '/api/v1/search',
      queryKeys: <String>{'title'},
    );
    await expectLater(
      transport.get(
        MoviesRequest(
          endpoint: other,
          uri: Uri.parse('http://127.0.0.1:${server.port}/api/v1/search'),
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('not allowed'),
        ),
      ),
    );
  });

  test(
    'rejects a non-digit or wrong-length code on an allowlisted route',
    () async {
      for (final path in <String>[
        '/api/v1/lookup/not-a-code',
        '/api/v1/lookup/0454',
        '/api/v1/lookup/ean/5051888100639',
      ]) {
        await expectLater(
          transport.get(
            requestFor(endpoint, path: path),
            timeout: const Duration(seconds: 5),
          ),
          throwsA(
            isA<ProviderException>().having(
              (e) => e.message,
              'message',
              contains('not allowed'),
            ),
          ),
          reason: path,
        );
      }
    },
  );

  test('requires https outside the test seam', () async {
    final strict = IoMoviesTransport(allowedEndpoints: <String>{endpoint.key});
    await expectLater(
      strict.get(requestFor(endpoint), timeout: const Duration(seconds: 5)),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('https'),
        ),
      ),
    );
  });

  test('rejects credentials in the URL and non-443 ports', () async {
    await expectLater(
      transport.get(
        MoviesRequest(
          endpoint: endpoint,
          uri: Uri.parse(
            'http://key:secret@127.0.0.1:${server.port}/api/v1/lookup/045496367619',
          ),
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('credentials in the URL'),
        ),
      ),
    );

    final strict = IoMoviesTransport(allowedEndpoints: <String>{endpoint.key});
    await expectLater(
      strict.get(
        MoviesRequest(
          endpoint: MoviesEndpoint(
            host: 'us-central1-upcmdb-cbae5.cloudfunctions.net',
            pathTemplate: '/api/v1/lookup/:upc',
            codeLength: 12,
          ),
          uri: Uri.parse(
            'https://us-central1-upcmdb-cbae5.cloudfunctions.net:8443/api/v1/lookup/045496367619',
          ),
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('port 443'),
        ),
      ),
    );
  });

  test('does not follow redirects and never replays the key', () async {
    var redirectedHits = 0;
    await serve((request) async {
      if (request.uri.path == '/elsewhere') {
        redirectedHits++;
        request.response
          ..statusCode = 200
          ..write('{}');
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = 302
        ..headers.set('location', 'http://127.0.0.1:${server.port}/elsewhere');
      await request.response.close();
    });

    final response = await transport.get(
      requestFor(
        endpoint,
        headers: <String, String>{'x-api-key': 'upcmdb-synthetic'},
      ),
      timeout: const Duration(seconds: 5),
    );

    expect(response.statusCode, 302);
    expect(redirectedHits, 0);
  });

  test('stops reading past the byte cap', () async {
    await serve((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json;
      for (var index = 0; index < 40; index++) {
        request.response.add(List<int>.filled(1024, 0x61));
      }
      await request.response.close();
    });

    await expectLater(
      transport.get(
        requestFor(endpoint),
        timeout: const Duration(seconds: 5),
        maxBytes: 4096,
      ),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('KiB'),
        ),
      ),
    );
  });

  test('honours the whole-request deadline', () async {
    await serve((request) async {
      // Never finishes: the deadline must abort it.
      await Completer<void>().future;
    });

    await expectLater(
      transport.get(
        requestFor(endpoint),
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(
        isA<ProviderException>()
            .having((e) => e.kind, 'kind', LookupFailureKind.timeout)
            .having((e) => e.message, 'message', contains('in time')),
      ),
    );
  });

  test('sanitizes network failures and status codes', () async {
    // A closed port is a network failure, not a crash.
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close(force: true);
    await expectLater(
      transport.get(
        MoviesRequest(
          endpoint: endpoint,
          uri: Uri.parse('http://127.0.0.1:$port/api/v1/lookup/045496367619'),
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.kind,
          'kind',
          LookupFailureKind.network,
        ),
      ),
    );

    expect(
      upcMdbStatusException(401).message,
      contains('rejected the API key'),
    );
    expect(upcMdbStatusException(403).message, contains('access'));
    expect(
      upcMdbStatusException(429, retryAfter: '45').retryAfter,
      const Duration(seconds: 45),
    );
    expect(upcMdbStatusException(500).kind, LookupFailureKind.unavailable);
    expect(upcMdbStatusException(418).kind, LookupFailureKind.http);
    expect(parseBoundedRetryAfter('not-a-number'), isNull);
    expect(parseBoundedRetryAfter('-5'), isNull);
    expect(parseBoundedRetryAfter('999999'), maxRetryAfter);
  });

  test('a malformed header value is rejected without echoing it', () async {
    await expectLater(
      transport.get(
        requestFor(
          endpoint,
          headers: <String, String>{'x-api-key': 'upcmdb-synthetic\u0000-leak'},
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<ProviderException>()
            .having((e) => e.kind, 'kind', LookupFailureKind.malformed)
            .having(
              (e) => e.message,
              'message',
              isNot(contains('upcmdb-synthetic')),
            ),
      ),
    );
  });
}
