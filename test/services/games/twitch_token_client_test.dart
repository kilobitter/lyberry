import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/games/twitch_token_client.dart';

import '../../support/fake_games.dart';

class _MutableClock implements Clock {
  _MutableClock(this._now);

  DateTime _now;

  void advance(Duration duration) => _now = _now.add(duration);

  @override
  DateTime nowUtc() => _now;
}

void main() {
  late FakeGamesTransport transport;
  late _MutableClock clock;

  setUp(() {
    transport = FakeGamesTransport();
    clock = _MutableClock(DateTime.utc(2026, 9, 25, 12));
  });

  TwitchTokenClient client() =>
      TwitchTokenClient(transport: transport, clock: clock);

  void enqueueToken({String token = 'app-token', int expiresIn = 3600}) =>
      transport.enqueue(
        GamesEndpoint.twitchToken.key,
        twitchToken(token: token, expiresIn: expiresIn),
      );

  test('exchanges credentials in a form body, never in the query', () async {
    enqueueToken();
    final value = await client().tokenFor(
      clientId: 'synthetic-client-id',
      clientSecret: 'synthetic-client-secret',
    );

    expect(value, 'app-token');
    final request = transport.requestAt(0);
    expect(request.endpoint, GamesEndpoint.twitchToken);
    expect(request.uri.query, isEmpty);
    expect(request.uri.toString(), isNot(contains('synthetic-client-secret')));
    expect(request.contentType, 'application/x-www-form-urlencoded');
    final body = Uri.splitQueryString(request.body!);
    expect(body['client_id'], 'synthetic-client-id');
    expect(body['client_secret'], 'synthetic-client-secret');
    expect(body['grant_type'], 'client_credentials');
  });

  test('caches the token and deduplicates concurrent acquisition', () async {
    enqueueToken();
    final first = client();
    final results = await Future.wait(<Future<String?>>[
      first.tokenFor(clientId: 'id', clientSecret: 'secret'),
      first.tokenFor(clientId: 'id', clientSecret: 'secret'),
      first.tokenFor(clientId: 'id', clientSecret: 'secret'),
    ]);
    expect(results, <String?>['app-token', 'app-token', 'app-token']);
    expect(transport.calls, 1);

    // A later call reuses the cached token.
    await first.tokenFor(clientId: 'id', clientSecret: 'secret');
    expect(transport.calls, 1);
  });

  test('a missing credential makes no request', () async {
    final value = await client().tokenFor(clientId: '', clientSecret: 'x');
    expect(value, isNull);
    expect(transport.calls, 0);
  });

  test('expiry is honoured with the skew removed', () async {
    enqueueToken(expiresIn: 120);
    final tokens = client();
    await tokens.tokenFor(clientId: 'id', clientSecret: 'secret');
    expect(transport.calls, 1);

    clock.advance(const Duration(seconds: 30));
    await tokens.tokenFor(clientId: 'id', clientSecret: 'secret');
    expect(transport.calls, 1);

    // The cache never outlives the reported lifetime (120s here, minus a
    // fifth as safety).
    clock.advance(const Duration(seconds: 80));
    enqueueToken(token: 'second-token');
    final refreshed = await tokens.tokenFor(
      clientId: 'id',
      clientSecret: 'secret',
    );
    expect(refreshed, 'second-token');
    expect(transport.calls, 2);
  });

  test('a short-lived token is never padded into a longer cache', () async {
    enqueueToken(expiresIn: 5);
    final tokens = client();
    await tokens.tokenFor(clientId: 'id', clientSecret: 'secret');
    expect(transport.calls, 1);

    clock.advance(const Duration(seconds: 5));
    enqueueToken(token: 'after-five-seconds');
    final refreshed = await tokens.tokenFor(
      clientId: 'id',
      clientSecret: 'secret',
    );
    expect(refreshed, 'after-five-seconds');
    expect(transport.calls, 2);
  });

  test('a control-bearing token is refused without echoing it', () async {
    const sentinel = 'sentinel-token-value';
    final scoped = FakeGamesTransport()
      ..enqueue(
        GamesEndpoint.twitchToken.key,
        FakeGamesCall(
          statusCode: 200,
          json: <String, Object?>{
            'access_token': '$sentinel\u0000tail',
            'expires_in': 3600,
            'token_type': 'bearer',
          },
        ),
      );
    await expectLater(
      TwitchTokenClient(
        transport: scoped,
        clock: clock,
      ).tokenFor(clientId: 'id', clientSecret: 'secret'),
      throwsA(
        isA<ProviderException>()
            .having((error) => error.kind, 'kind', LookupFailureKind.malformed)
            .having(
              (error) => error.message,
              'message',
              isNot(contains(sentinel)),
            ),
      ),
    );
  });

  test('a stale 401 cannot discard a newer token', () async {
    enqueueToken(token: 'first');
    final tokens = client();
    await tokens.tokenFor(clientId: 'id', clientSecret: 'secret');
    final staleGeneration = tokens.generation;

    // A credential change (or another invalidation) happens, then a new token
    // is acquired. The old 401 must not clear it.
    tokens.invalidate();
    enqueueToken(token: 'newer');
    final newer = await tokens.tokenFor(clientId: 'id', clientSecret: 'secret');
    expect(newer, 'newer');

    tokens.invalidateIf(generation: staleGeneration);
    final stillNewer = await tokens.tokenFor(
      clientId: 'id',
      clientSecret: 'secret',
    );
    expect(stillNewer, 'newer');
    expect(transport.calls, 2);
  });

  test('replacing credentials invalidates the cached token', () async {
    enqueueToken(token: 'first-token');
    final tokens = client();
    await tokens.tokenFor(clientId: 'id', clientSecret: 'one');

    enqueueToken(token: 'second-token');
    final second = await tokens.tokenFor(clientId: 'id', clientSecret: 'two');
    expect(second, 'second-token');
    expect(transport.calls, 2);
  });

  test('a pending exchange cannot survive invalidation', () async {
    transport.enqueue(
      GamesEndpoint.twitchToken.key,
      FakeGamesCall(
        statusCode: 200,
        json: <String, Object?>{
          'access_token': 'stale-token',
          'expires_in': 3600,
          'token_type': 'bearer',
        },
        delay: const Duration(milliseconds: 120),
      ),
    );
    final tokens = client();
    final pending = tokens.tokenFor(clientId: 'id', clientSecret: 'secret');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    tokens.invalidate();

    await expectLater(
      pending,
      throwsA(
        isA<ProviderException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.unavailable,
        ),
      ),
    );

    // The next call must exchange again instead of reusing the stale token.
    enqueueToken(token: 'fresh-token');
    final fresh = await tokens.tokenFor(clientId: 'id', clientSecret: 'secret');
    expect(fresh, 'fresh-token');
    expect(transport.calls, 2);
  });

  test('validates the token response shape and type', () async {
    for (final json in <Object?>[
      <String, Object?>{'expires_in': 3600},
      <String, Object?>{'access_token': '  '},
      <String, Object?>{
        'access_token': 'token',
        'token_type': 'mac',
        'expires_in': 3600,
      },
      <Object?>['not', 'a', 'map'],
    ]) {
      final scoped = FakeGamesTransport()
        ..enqueue(
          GamesEndpoint.twitchToken.key,
          FakeGamesCall(statusCode: 200, json: json),
        );
      await expectLater(
        TwitchTokenClient(
          transport: scoped,
          clock: clock,
        ).tokenFor(clientId: 'id', clientSecret: 'secret'),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
      );
    }
  });

  test('token failures stay sanitized', () async {
    final scoped = FakeGamesTransport()
      ..enqueue(
        GamesEndpoint.twitchToken.key,
        FakeGamesCall(
          statusCode: 400,
          body: 'client_secret=synthetic-client-secret',
        ),
      );
    await expectLater(
      TwitchTokenClient(transport: scoped, clock: clock).tokenFor(
        clientId: 'synthetic-client-id',
        clientSecret: 'synthetic-client-secret',
      ),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.message,
          'message',
          isNot(contains('synthetic-client-secret')),
        ),
      ),
    );
  });
}
