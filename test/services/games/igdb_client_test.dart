import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/games/games_request_gate.dart';
import 'package:lyberry/services/games/igdb_client.dart';
import 'package:lyberry/services/games/twitch_token_client.dart';
import 'package:lyberry/services/rate_limiter.dart';

import '../../support/fake_games.dart';

void main() {
  late FakeGamesTransport transport;
  late TwitchTokenClient tokens;

  setUp(() {
    transport = FakeGamesTransport();
    tokens = TwitchTokenClient(transport: transport);
  });

  IgdbClient client({
    Duration minInterval = const Duration(milliseconds: 10),
  }) => IgdbClient(
    transport: transport,
    tokens: tokens,
    credentials: () async =>
        (clientId: 'synthetic-client-id', clientSecret: 'synthetic-secret'),
    gate: GamesRequestGate(
      limiter: ProviderRateLimiter(
        providerId: 'igdb',
        minInterval: minInterval,
      ),
    ),
  );

  void enqueueToken() => transport.enqueue(
    GamesEndpoint.twitchToken.key,
    twitchToken(token: 'app-token'),
  );

  void enqueueIgdb(FakeGamesCall call) =>
      transport.enqueue(GamesEndpoint.igdbGames.key, call);

  test('fetches by exact id with explicit fields and headers', () async {
    enqueueToken();
    enqueueIgdb(
      igdbGame(
        id: 7346,
        name: 'Wii Sports Resort',
        url: 'https://www.igdb.com/games/wii-sports-resort',
        summary: 'A resort island sports game.',
        imageId: 'co1abc',
        platformIds: <int>[5],
        platformNames: <String, String>{'5': 'Wii'},
        releaseYears: <int, int>{5: 2009},
        developer: 'Nintendo',
        publisher: 'Nintendo',
      ),
    );

    final game = await client().gameById(7346);
    expect(game, isNotNull);
    expect(game!.name, 'Wii Sports Resort');
    expect(game.creator, 'Nintendo');
    expect(game.publisher, 'Nintendo');
    expect(game.summary, 'A resort island sports game.');
    expect(game.yearFor(5), 2009);
    expect(game.yearFor(6), isNull, reason: 'never a wrong-platform year');
    expect(
      game.coverUrl,
      'https://images.igdb.com/igdb/image/upload/t_cover_big/co1abc.jpg',
    );

    final request = transport.requestAt(1);
    expect(request.endpoint, GamesEndpoint.igdbGames);
    expect(request.headers['Client-ID'], 'synthetic-client-id');
    expect(request.headers['Authorization'], 'Bearer app-token');
    expect(request.body, contains('where id = 7346'));
    expect(request.body, contains('platforms.id'));
    expect(request.body, contains('release_dates.y'));
    expect(request.body, contains('cover.image_id'));
    expect(request.body, contains('limit 1;'));
    expect(
      request.body,
      isNot(contains('first_release_date')),
      reason: 'a platform-less date must not become a platform year',
    );
  });

  test('refreshes the token exactly once on a 401', () async {
    transport
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken(token: 'first'))
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(statusCode: 401, body: 'unauthorized'),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken(token: 'second'))
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        igdbGame(id: 1, name: 'Game', platformIds: <int>[1]),
      );

    final game = await client().gameById(1);
    expect(game!.name, 'Game');
    expect(transport.endpoints, <String>[
      GamesEndpoint.twitchToken.key,
      GamesEndpoint.igdbGames.key,
      GamesEndpoint.twitchToken.key,
      GamesEndpoint.igdbGames.key,
    ]);
  });

  test('a second 401 fails without another retry', () async {
    transport
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken(token: 'first'))
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(statusCode: 401, body: 'no'),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken(token: 'second'))
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(statusCode: 401, body: 'no'),
      );

    await expectLater(
      client().gameById(1),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.http,
        ),
      ),
    );
    expect(transport.calls, 4);
  });

  test('429 is a quota failure and is not retried', () async {
    enqueueToken();
    enqueueIgdb(FakeGamesCall(statusCode: 429, body: 'slow down'));

    await expectLater(
      client().gameById(1),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.quota,
        ),
      ),
    );
    expect(transport.calls, 2);
  });

  test('title search escapes the query and validates input', () async {
    enqueueToken();
    enqueueIgdb(igdbEmpty());
    await client().searchByTitle('Half "Life" \\ 2');

    final body = transport.requestAt(1).body!;
    expect(body, contains(r'search "Half \"Life\" \\ 2"'));
    expect(body, contains('limit 20;'));

    for (final bad in <String>['', '   ', 'a' * 200, 'bad\u0000title']) {
      final scoped = FakeGamesTransport();
      final scopedClient = IgdbClient(
        transport: scoped,
        tokens: TwitchTokenClient(transport: scoped),
        credentials: () async => (clientId: 'id', clientSecret: 'secret'),
        gate: GamesRequestGate(
          limiter: ProviderRateLimiter(
            providerId: 'igdb',
            minInterval: Duration.zero,
          ),
        ),
      );
      await expectLater(
        scopedClient.searchByTitle(bad),
        throwsA(isA<ProviderException>()),
      );
      expect(scoped.calls, 0, reason: 'invalid titles make no request');
    }
  });

  test('malformed answers are rejected without inventing games', () async {
    enqueueToken();
    enqueueIgdb(FakeGamesCall(statusCode: 200, body: 'not json'));
    await expectLater(
      client().gameById(1),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.malformed,
        ),
      ),
    );

    final scoped = FakeGamesTransport()
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(statusCode: 200, json: <String, Object?>{'games': []}),
      );
    await expectLater(
      IgdbClient(
        transport: scoped,
        tokens: TwitchTokenClient(transport: scoped),
        credentials: () async => (clientId: 'id', clientSecret: 'secret'),
        gate: GamesRequestGate(
          limiter: ProviderRateLimiter(
            providerId: 'igdb',
            minInterval: Duration.zero,
          ),
        ),
      ).gameById(1),
      throwsA(isA<ProviderException>()),
    );

    final mixed = FakeGamesTransport()
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(
          statusCode: 200,
          json: <Object?>[
            <String, Object?>{'id': 0, 'name': 'bad id'},
            <String, Object?>{'id': 5, 'name': 'good'},
            'not a map',
          ],
        ),
      );
    final games = await IgdbClient(
      transport: mixed,
      tokens: TwitchTokenClient(transport: mixed),
      credentials: () async => (clientId: 'id', clientSecret: 'secret'),
      gate: GamesRequestGate(
        limiter: ProviderRateLimiter(
          providerId: 'igdb',
          minInterval: Duration.zero,
        ),
      ),
    ).gameById(5);
    expect(games!.id, 5);
  });

  test('cover URLs are built only from a validated image id', () {
    expect(IgdbClient.coverUrlFromImageId(''), isNull);
    expect(IgdbClient.coverUrlFromImageId('  '), isNull);
    expect(IgdbClient.coverUrlFromImageId('../../etc/passwd'), isNull);
    expect(IgdbClient.coverUrlFromImageId('a b'), isNull);
    expect(IgdbClient.coverUrlFromImageId('a' * 200), isNull);
    expect(
      IgdbClient.coverUrlFromImageId('co1abc'),
      'https://images.igdb.com/igdb/image/upload/t_cover_big/co1abc.jpg',
    );
  });

  test('the shared limiter spaces consecutive requests', () async {
    enqueueToken();
    enqueueIgdb(igdbEmpty());
    enqueueIgdb(igdbEmpty());
    final scoped = client(minInterval: const Duration(milliseconds: 300));

    final watch = Stopwatch()..start();
    await scoped.gameById(1);
    await scoped.searchByTitle('second');
    watch.stop();

    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
  });

  test('a different game id is rejected instead of substituted', () async {
    enqueueToken();
    enqueueIgdb(igdbGame(id: 999, name: 'Wrong game'));
    await expectLater(
      client().gameById(1),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.kind,
          'kind',
          LookupFailureKind.malformed,
        ),
      ),
    );
  });

  test('a Unix-seconds release date becomes a UTC year', () async {
    enqueueToken();
    enqueueIgdb(
      FakeGamesCall(
        statusCode: 200,
        json: <Object?>[
          <String, Object?>{
            'id': 5,
            'name': 'Dated game',
            'platforms': <Object?>[
              <String, Object?>{'id': 19, 'name': 'Super Nintendo'},
            ],
            // 1990-11-21T00:00:00Z as Unix seconds; no `y` field.
            'release_dates': <Object?>[
              <String, Object?>{'platform': 19, 'date': 659232000},
            ],
          },
        ],
      ),
    );
    final game = await client().gameById(5);
    expect(game!.yearFor(19), 1990);
  });

  test('provenance URLs are restricted to IGDB https hosts', () async {
    enqueueToken();
    enqueueIgdb(
      igdbGame(
        id: 5,
        name: 'URL game',
        url: 'https://evil.example/track?token=x',
      ),
    );
    final hostile = await client().gameById(5);
    expect(hostile!.url, isEmpty);

    final scoped = FakeGamesTransport()
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        igdbGame(
          id: 6,
          name: 'URL game',
          url: 'https://user:pass@www.igdb.com:8443/games/x',
        ),
      );
    final credentialed = await IgdbClient(
      transport: scoped,
      tokens: TwitchTokenClient(transport: scoped),
      credentials: () async => (clientId: 'id', clientSecret: 'secret'),
      gate: GamesRequestGate(
        limiter: ProviderRateLimiter(
          providerId: 'igdb',
          minInterval: Duration.zero,
        ),
      ),
    ).gameById(6);
    expect(credentialed!.url, isEmpty);
  });

  test(
    'a credential change while queued for a gate slot sends nothing',
    () async {
      transport
        ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
        ..enqueue(
          GamesEndpoint.igdbGames.key,
          FakeGamesCall(
            statusCode: 200,
            json: <Object?>[
              <String, Object?>{'id': 1, 'name': 'First'},
            ],
            delay: const Duration(milliseconds: 200),
          ),
        )
        ..enqueue(GamesEndpoint.igdbGames.key, igdbEmpty());

      var stale = false;
      final subject = IgdbClient(
        transport: transport,
        tokens: tokens,
        credentials: () async =>
            (clientId: 'synthetic-client-id', clientSecret: 'synthetic-secret'),
        gate: GamesRequestGate(
          limiter: ProviderRateLimiter(
            providerId: 'igdb',
            minInterval: Duration.zero,
          ),
          maxConcurrent: 1,
        ),
        isStale: () => stale,
      );

      final first = subject.gameById(1);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      // Second request queues behind the first; the credentials are then changed.
      final second = subject.gameById(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      stale = true;

      await first;
      await expectLater(
        second,
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.unavailable,
          ),
        ),
      );

      final igdbPosts = transport.requests
          .where((request) => request.endpoint == GamesEndpoint.igdbGames)
          .length;
      expect(igdbPosts, 1, reason: 'the queued request was never sent');
    },
  );

  test('a huge Unix release date is ignored instead of throwing', () async {
    enqueueToken();
    enqueueIgdb(
      FakeGamesCall(
        statusCode: 200,
        json: <Object?>[
          <String, Object?>{
            'id': 8,
            'name': 'Malformed date game',
            'platforms': <Object?>[
              <String, Object?>{'id': 19, 'name': 'Super Nintendo'},
            ],
            'release_dates': <Object?>[
              <String, Object?>{'platform': 19, 'date': 999999999999999},
            ],
          },
        ],
      ),
    );
    final game = await client().gameById(8);
    expect(game!.yearFor(19), isNull);
  });
}
