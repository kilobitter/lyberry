import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/games_transport.dart';

void main() {
  late HttpServer server;
  late GamesEndpoint endpoint;
  late IoGamesTransport transport;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = GamesEndpoint(
      host: '127.0.0.1',
      path: '/api/v2/lookup',
      method: GamesHttpMethod.get,
    );
    transport = IoGamesTransport(
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

  GamesRequest requestFor(
    GamesEndpoint target, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) => GamesRequest(
    endpoint: target,
    uri: Uri.parse('http://127.0.0.1:${server.port}${target.path}'),
    headers: headers,
    body: body,
    contentType: 'text/plain',
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
        ..write(jsonEncode(<String, Object?>{'ok': true}));
      await request.response.close();
    });

    final response = await transport.send(
      requestFor(
        endpoint,
        headers: <String, String>{'Authorization': 'synthetic-token'},
      ),
      timeout: const Duration(seconds: 5),
    );

    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), <String, Object?>{'ok': true});
    expect(headers['authorization'], 'synthetic-token');
  });

  test('rejects an endpoint that is not on the allowlist', () async {
    final other = GamesEndpoint(
      host: '127.0.0.1',
      path: '/v4/games',
      method: GamesHttpMethod.post,
    );
    await expectLater(
      transport.send(
        requestFor(other, body: 'fields name;'),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.message,
          'message',
          contains('not allowed'),
        ),
      ),
    );
  });

  test('requires https outside the test seam', () async {
    final strict = IoGamesTransport(allowedEndpoints: <String>{endpoint.key});
    await expectLater(
      strict.send(requestFor(endpoint), timeout: const Duration(seconds: 5)),
      throwsA(isA<ProviderException>()),
    );
  });

  test('rejects credentials in the URL and non-443 ports', () async {
    final strict = IoGamesTransport(allowedEndpoints: <String>{endpoint.key});
    await expectLater(
      strict.send(
        GamesRequest(
          endpoint: endpoint,
          uri: Uri.parse('https://user:pass@127.0.0.1/api/v2/lookup'),
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(isA<ProviderException>()),
    );
    await expectLater(
      strict.send(
        GamesRequest(
          endpoint: endpoint,
          uri: Uri.parse('https://127.0.0.1:8443/api/v2/lookup'),
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(isA<ProviderException>()),
    );
  });

  test('does not follow redirects and never replays credentials', () async {
    var followed = false;
    var leaked = false;
    await serve((request) async {
      if (request.uri.path == '/target') {
        followed = true;
        request.headers.forEach((name, values) {
          if (name.toLowerCase() == 'authorization') leaked = true;
        });
      }
      request.response
        ..statusCode = 302
        ..headers.set(HttpHeaders.locationHeader, '/target');
      await request.response.close();
    });

    final response = await transport.send(
      requestFor(
        endpoint,
        headers: <String, String>{'Authorization': 'synthetic-token'},
      ),
      timeout: const Duration(seconds: 5),
    );

    expect(response.statusCode, 302);
    expect(followed, isFalse);
    expect(leaked, isFalse);
  });

  test('stops reading past the byte cap', () async {
    await serve((request) async {
      request.response
        ..statusCode = 200
        ..add(List<int>.filled(64 * 1024, 0x61));
      await request.response.close();
    });

    await expectLater(
      transport.send(
        requestFor(endpoint),
        timeout: const Duration(seconds: 5),
        maxBytes: 1024,
      ),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.malformed,
        ),
      ),
    );
  });

  test('honours the whole-request deadline', () async {
    await serve((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      request.response
        ..statusCode = 200
        ..write('slow');
      await request.response.close();
    });

    await expectLater(
      transport.send(
        requestFor(endpoint),
        timeout: const Duration(milliseconds: 80),
      ),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.timeout,
        ),
      ),
    );
  });

  test('sanitizes network failures and status codes', () {
    final network = ProviderException(
      LookupFailureKind.network,
      'A games service could not be reached.',
    );
    expect(network.message, isNot(contains('127.0.0.1')));

    for (final (status, kind) in <(int, LookupFailureKind)>[
      (401, LookupFailureKind.http),
      (403, LookupFailureKind.http),
      (429, LookupFailureKind.quota),
      (503, LookupFailureKind.unavailable),
      (418, LookupFailureKind.http),
    ]) {
      final error = gamesStatusException(status, 'IGDB');
      expect(error.kind, kind);
      expect(error.message, contains('IGDB'));
      expect(
        error.message,
        isNot(contains('body')),
        reason: 'response text is never reflected',
      );
    }
    expect(
      gamesStatusException(401, 'Twitch').message,
      isNot(contains('Bearer')),
    );
  });

  test('a malformed header value is rejected without echoing it', () async {
    const sentinel = 'sentinel-authorization-value';
    await serve((request) async {
      request.response
        ..statusCode = 200
        ..write('should not be reached');
      await request.response.close();
    });

    await expectLater(
      transport.send(
        requestFor(
          endpoint,
          headers: <String, String>{'Authorization': '$sentinel\u0000tail'},
        ),
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        isA<ProviderException>()
            .having((error) => error.kind, 'kind', LookupFailureKind.malformed)
            .having(
              (error) => error.message,
              'message',
              isNot(contains(sentinel)),
            )
            .having(
              (error) => error.message,
              'message',
              isNot(contains('Dart')),
            ),
      ),
    );
  });
}
