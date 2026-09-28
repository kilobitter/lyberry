import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/games/games_lookup_service.dart';
import 'package:lyberry/services/games/games_request_gate.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/rate_limiter.dart';

import '../../support/fake_games.dart';
import '../../support/fake_web.dart';
import '../../support/stub_provider.dart';

void main() {
  late FakeGamesTransport transport;
  late InMemoryApiKeyStore keys;
  late LookupCache cache;
  late ProviderRateLimiter limiter;
  late GamesLookupService service;

  InMemoryApiKeyStore configuredKeys({
    bool scanDex = true,
    bool twitch = true,
  }) => InMemoryApiKeyStore(
    initial: <CredentialKey, String>{
      if (scanDex) GamesKeyProvider.scandex: 'scandex-synthetic',
      if (twitch) GamesKeyProvider.twitchId: 'synthetic-client-id',
      if (twitch) GamesKeyProvider.twitchSecret: 'synthetic-secret',
    },
  );

  void build({
    InMemoryApiKeyStore? keyStore,
    Duration minInterval = const Duration(milliseconds: 10),
  }) {
    keys = keyStore ?? configuredKeys();
    cache = LookupCache();
    limiter = ProviderRateLimiter(
      providerId: GamesLookupService.providerId,
      minInterval: minInterval,
    );
    service = GamesLookupService(
      keys: keys,
      transport: transport,
      gate: GamesRequestGate(limiter: limiter),
      cache: cache,
    );
  }

  setUp(() {
    transport = FakeGamesTransport();
    build();
  });

  LookupQuery query(String code, {MediaType? medium = MediaType.game}) =>
      LookupQuery(
        identifier: IdentifierNormalizer.normalize(code),
        mediumHint: medium,
      );

  void enqueueWii({String source = 'imported'}) {
    transport
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 7346,
          name: 'Wii Sports Resort',
          platformId: 5,
          platformName: 'Wii',
          source: source,
        ),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        igdbGame(
          id: 7346,
          name: 'Wii Sports Resort',
          url: 'https://www.igdb.com/games/wii-sports-resort',
          summary: 'Resort island sports.',
          imageId: 'co1abc',
          platformIds: <int>[5],
          platformNames: <String, String>{'5': 'Wii'},
          releaseYears: <int, int>{5: 2009},
          developer: 'Nintendo',
          publisher: 'Nintendo',
        ),
      );
  }

  test(
    'resolves the Wii UPC and its equivalent EAN through ScanDex+IGDB',
    () async {
      enqueueWii();
      final result = await service.lookup(query('045496367619'));

      expect(result.candidates, hasLength(1));
      final candidate = result.candidates.single;
      expect(candidate.providerId, 'igdb');
      expect(candidate.medium, MediaType.game);
      expect(candidate.title, 'Wii Sports Resort');
      expect(candidate.platform, 'Wii');
      expect(candidate.year, 2009);
      expect(candidate.creator, 'Nintendo');
      expect(candidate.publisher, 'Nintendo');
      expect(candidate.matchKind, MatchKind.exact);
      expect(candidate.externalId, 'igdb:7346:5');
      expect(
        candidate.coverUrl,
        'https://images.igdb.com/igdb/image/upload/t_cover_big/co1abc.jpg',
      );
      // The scanned UPC keeps its leading zero.
      expect(
        transport.requestAt(0).uri.queryParameters['value'],
        '045496367619',
      );
      expect(transport.requestAt(2).body, contains('where id = 7346'));
      expect(result.warning, isNull);

      // The zero-padded EAN equivalent resolves identically.
      final secondTransport = FakeGamesTransport();
      final secondKeys = configuredKeys();
      final secondService = GamesLookupService(
        keys: secondKeys,
        transport: secondTransport,
        gate: GamesRequestGate(
          limiter: ProviderRateLimiter(
            providerId: GamesLookupService.providerId,
            minInterval: Duration.zero,
          ),
        ),
      );
      secondTransport
        ..enqueue(
          GamesEndpoint.scanDexLookup.key,
          scanDexMatch(
            gameId: 7346,
            name: 'Wii Sports Resort',
            platformId: 5,
            platformName: 'Wii',
          ),
        )
        ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
        ..enqueue(
          GamesEndpoint.igdbGames.key,
          igdbGame(
            id: 7346,
            name: 'Wii Sports Resort',
            platformIds: <int>[5],
            platformNames: <String, String>{'5': 'Wii'},
            releaseYears: <int, int>{5: 2009},
          ),
        );
      final equivalent = await secondService.lookup(query('0045496367619'));
      expect(equivalent.candidates.single.title, 'Wii Sports Resort');
      expect(equivalent.candidates.single.year, 2009);
    },
  );

  test('a community ScanDex source is only a possible match', () async {
    enqueueWii(source: 'user');
    final result = await service.lookup(query('045496367619'));
    expect(result.candidates.single.matchKind, MatchKind.possible);
  });

  test('uses only the chosen platform release year', () async {
    transport
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 1,
          name: 'Multi platform game',
          platformId: 7,
          platformName: 'PlayStation 4',
        ),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        igdbGame(
          id: 1,
          name: 'Multi platform game',
          platformIds: <int>[5, 7],
          platformNames: <String, String>{'5': 'Wii', '7': 'PlayStation 4'},
          releaseYears: <int, int>{5: 2009, 7: 2013},
        ),
      );

    final result = await service.lookup(query('045496367619'));
    final candidate = result.candidates.single;
    expect(candidate.platform, 'PlayStation 4');
    expect(candidate.year, 2013);
  });

  test(
    'a platform mismatch keeps the ScanDex candidate, never another console',
    () async {
      transport
        ..enqueue(
          GamesEndpoint.scanDexLookup.key,
          scanDexMatch(
            gameId: 1,
            name: 'Game',
            platformId: 99,
            platformName: 'Unlisted console',
          ),
        )
        ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
        ..enqueue(
          GamesEndpoint.igdbGames.key,
          igdbGame(
            id: 1,
            name: 'Game',
            platformIds: <int>[5],
            platformNames: <String, String>{'5': 'Wii'},
            releaseYears: <int, int>{5: 2009},
          ),
        );

      final result = await service.lookup(query('045496367619'));
      final candidate = result.candidates.single;
      expect(candidate.providerId, 'scandex');
      expect(candidate.platform, 'Unlisted console');
      expect(candidate.year, isNull);
      expect(result.warning?.kind, LookupFailureKind.malformed);
      expect(result.warning?.message, contains('platform'));
    },
  );

  test('an IGDB failure keeps the trustworthy ScanDex fields', () async {
    transport
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 1,
          name: 'Game',
          platformId: 5,
          platformName: 'Wii',
        ),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(statusCode: 429, body: 'slow down'),
      );

    final result = await service.lookup(query('045496367619'));
    expect(result.candidates.single.providerId, 'scandex');
    expect(result.candidates.single.platform, 'Wii');
    expect(result.warning?.kind, LookupFailureKind.quota);
  });

  test('missing ScanDex credentials make no request', () async {
    build(keyStore: configuredKeys(scanDex: false));
    await expectLater(
      service.lookup(query('045496367619')),
      throwsA(
        isA<ProviderException>().having(
          (error) => error.message,
          'message',
          contains('ScanDex'),
        ),
      ),
    );
    expect(transport.calls, 0);

    // An unrelated automatic lookup stays silent instead of warning.
    final quiet = await service.lookup(query('045496367619', medium: null));
    expect(quiet.candidates, isEmpty);
    expect(quiet.warning, isNull);
    expect(transport.calls, 0);
  });

  test(
    'missing Twitch credentials keep the ScanDex partial candidate',
    () async {
      build(keyStore: configuredKeys(twitch: false));
      transport.enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 1,
          name: 'Game',
          platformId: 5,
          platformName: 'Wii',
        ),
      );

      final result = await service.lookup(query('045496367619'));
      expect(result.candidates.single.providerId, 'scandex');
      expect(result.warning?.kind, LookupFailureKind.unavailable);
      expect(transport.calls, 1);
    },
  );

  test('title search without Twitch credentials makes no request', () async {
    build(keyStore: configuredKeys(twitch: false));
    final outcome = await service.searchByTitle('Wii Sports Resort');
    expect(outcome.candidates, isEmpty);
    expect(outcome.failure?.kind, LookupFailureKind.unavailable);
    expect(outcome.failure?.message, contains('Twitch'));
    expect(transport.calls, 0);
  });

  test(
    'title search returns one bounded candidate per game and platform',
    () async {
      transport
        ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
        ..enqueue(
          GamesEndpoint.igdbGames.key,
          FakeGamesCall(
            statusCode: 200,
            json: <Object?>[
              <String, Object?>{
                'id': 1,
                'name': 'Multi platform game',
                'platforms': <Object?>[
                  <String, Object?>{'id': 5, 'name': 'Wii'},
                  <String, Object?>{'id': 7, 'name': 'PlayStation 4'},
                ],
                'release_dates': <Object?>[
                  <String, Object?>{'platform': 5, 'y': 2009},
                  <String, Object?>{'platform': 7, 'y': 2013},
                ],
              },
              <String, Object?>{'id': 2, 'name': 'Platform-less game'},
              <String, Object?>{
                'id': 3,
                'name': 'Many platforms',
                'platforms': <Object?>[
                  for (var index = 1; index <= 12; index++)
                    <String, Object?>{'id': index, 'name': 'Platform $index'},
                ],
              },
            ],
          ),
        );

      final outcome = await service.searchByTitle('game');
      expect(outcome.failure, isNull);
      final externalIds = outcome.candidates
          .map((candidate) => candidate.externalId)
          .toList();
      expect(externalIds.toSet().length, externalIds.length, reason: 'deduped');
      expect(
        outcome.candidates.every(
          (candidate) => candidate.medium == MediaType.game,
        ),
        isTrue,
      );
      expect(
        outcome.candidates
            .firstWhere((candidate) => candidate.externalId == 'igdb:1:7')
            .year,
        2013,
      );
      expect(
        outcome.candidates
            .firstWhere((candidate) => candidate.externalId == 'igdb:2:any')
            .year,
        isNull,
        reason: 'no platform, no year',
      );
      expect(
        outcome.candidates
            .where((candidate) => candidate.externalId.startsWith('igdb:3:'))
            .length,
        GamesLookupService.maxPlatformsPerGame,
      );
      expect(
        outcome.candidates.length,
        lessThanOrEqualTo(GamesLookupService.maxGameCandidates),
      );
    },
  );

  test('credential invalidation discards an in-flight answer', () async {
    transport.enqueue(
      GamesEndpoint.scanDexLookup.key,
      FakeGamesCall(
        statusCode: 200,
        json: <String, Object?>{
          'source': 'imported',
          'igdb_metadata': <String, Object?>{
            'id': 1,
            'name': 'Game',
            'platform': <String, Object?>{'id': 5, 'name': 'Wii'},
          },
        },
        delay: const Duration(milliseconds: 120),
      ),
    );

    final pending = service.lookup(query('045496367619'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    service.invalidateCredentials();

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
  });

  test('invalidation clears the shared cache and token state', () async {
    cache.put('5051888100639|game', <MetadataCandidate>[
      MetadataCandidate(
        providerId: 'igdb',
        providerLabel: 'IGDB',
        externalId: 'igdb:1:5',
        matchKind: MatchKind.possible,
        title: 'Cached',
        medium: MediaType.game,
      ),
    ]);
    expect(cache.length, 1);
    service.invalidateCredentials();
    expect(cache.length, 0);

    // A new lookup can use the new credentials immediately.
    await keys.write(GamesKeyProvider.scandex, 'new-scandex-token');
    transport
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 2,
          name: 'Fresh',
          platformId: 5,
          platformName: 'Wii',
        ),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken());
    final result = await service.lookup(query('045496367619'));
    expect(result.candidates, isNotEmpty);
    expect(
      transport.requestAt(0).headers['Authorization'],
      'new-scandex-token',
    );
  });

  test('the same limiter spaces barcode and title work', () async {
    build(minInterval: const Duration(milliseconds: 300));
    enqueueWii();
    await service.lookup(query('045496367619'));
    expect(limiter.cooldownRemaining, greaterThan(Duration.zero));

    transport.enqueue(GamesEndpoint.igdbGames.key, igdbEmpty());
    final watch = Stopwatch()..start();
    await service.searchByTitle('another');
    watch.stop();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(200));
  });

  test('an IGDB id mismatch keeps a downgraded ScanDex partial', () async {
    transport
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 7346,
          name: 'Wii Sports Resort',
          platformId: 5,
          platformName: 'Wii',
          source: 'import',
        ),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(GamesEndpoint.igdbGames.key, igdbGame(id: 999, name: 'Other'));

    final result = await service.lookup(query('045496367619'));
    final candidate = result.candidates.single;
    expect(candidate.providerId, 'scandex');
    expect(candidate.matchKind, MatchKind.possible);
    expect(candidate.year, isNull);
    expect(result.warning?.kind, LookupFailureKind.malformed);
  });

  test('an invalidation during enrichment rejects the result', () async {
    transport
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 1,
          name: 'Game',
          platformId: 5,
          platformName: 'Wii',
        ),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(
          statusCode: 200,
          json: <Object?>[
            <String, Object?>{
              'id': 1,
              'name': 'Game',
              'platforms': <Object?>[
                <String, Object?>{'id': 5, 'name': 'Wii'},
              ],
              'release_dates': <Object?>[
                <String, Object?>{'platform': 5, 'y': 2009},
              ],
            },
          ],
          delay: const Duration(milliseconds: 150),
        ),
      );

    final pending = service.lookup(query('045496367619'));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    service.invalidateCredentials();

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
  });

  test('a keystore read failure is not reported as a missing key', () async {
    final failing = configuredKeys();
    failing.readFailures[GamesKeyProvider.scandex] = const WebLookupException(
      WebFailureKind.unavailable,
      'ScanDex API token could not be read on this device.',
      stage: WebLookupStage.keys,
    );
    build(keyStore: failing);

    await expectLater(
      service.lookup(query('045496367619')),
      throwsA(
        isA<ProviderException>()
            .having(
              (error) => error.kind,
              'kind',
              LookupFailureKind.unavailable,
            )
            .having(
              (error) => error.message,
              'message',
              contains('could not be read'),
            )
            .having(
              (error) => error.message,
              'message',
              isNot(contains('Add your ScanDex')),
            ),
      ),
    );
    expect(transport.calls, 0);
  });

  test(
    'only the enrichment credentials failing keeps the ScanDex partial',
    () async {
      final partialKeys = configuredKeys();
      partialKeys.readFailures[GamesKeyProvider.twitchId] =
          const WebLookupException(
            WebFailureKind.unavailable,
            'Twitch client ID could not be read on this device.',
            stage: WebLookupStage.keys,
          );
      build(keyStore: partialKeys);
      transport.enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 1,
          name: 'Game',
          platformId: 5,
          platformName: 'Wii',
        ),
      );

      final result = await service.lookup(query('045496367619'));
      final candidate = result.candidates.single;
      expect(candidate.providerId, 'scandex');
      expect(candidate.matchKind, MatchKind.possible);
      expect(result.warning?.message, contains('could not be read'));
      expect(result.warning?.message, isNot(contains('Add your Twitch')));
      expect(transport.calls, 1);
    },
  );

  test('a 429 cooldown stops the next path from sending', () async {
    transport
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 1,
          name: 'Game',
          platformId: 5,
          platformName: 'Wii',
        ),
      )
      ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
      ..enqueue(
        GamesEndpoint.igdbGames.key,
        FakeGamesCall(
          statusCode: 429,
          body: 'slow down',
          headers: <String, String>{'retry-after': '2'},
        ),
      );

    final first = await service.lookup(query('045496367619'));
    expect(first.warning?.kind, LookupFailureKind.quota);
    expect(service.cooldownRemaining, greaterThan(Duration.zero));
    final callsAfterFirst = transport.calls;

    // The title path shares the limiter, so it fails with a cooldown instead of
    // sending a fresh request.
    final second = await service.searchByTitle('anything');
    expect(second.failure?.kind, LookupFailureKind.cooldown);
    expect(transport.calls, callsAfterFirst);
  });

  test(
    'invalidating during a delayed ScanDex key read sends no request',
    () async {
      final slowKeys = configuredKeys();
      slowKeys.readDelay = const Duration(milliseconds: 120);
      build(keyStore: slowKeys);

      final pending = service.lookup(query('045496367619'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      service.invalidateCredentials();

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
      expect(transport.calls, 0, reason: 'no ScanDex request after the change');
    },
  );

  test(
    'invalidating during a delayed credential read sends no IGDB request',
    () async {
      final slowKeys = configuredKeys();
      slowKeys.readDelays[GamesKeyProvider.twitchId] = const Duration(
        milliseconds: 120,
      );
      slowKeys.readDelays[GamesKeyProvider.twitchSecret] = const Duration(
        milliseconds: 120,
      );
      build(keyStore: slowKeys);
      transport.enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(
          gameId: 1,
          name: 'Game',
          platformId: 5,
          platformName: 'Wii',
        ),
      );

      final pending = service.lookup(query('045496367619'));
      // ScanDex has answered; the enrichment credential read is still pending.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      service.invalidateCredentials();

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
      final igdbPosts = transport.requests
          .where((request) => request.endpoint == GamesEndpoint.igdbGames)
          .length;
      expect(igdbPosts, 0);
    },
  );

  test(
    'a credential change does not penalize the shared IGDB limiter',
    () async {
      final limiter = ProviderRateLimiter(
        providerId: GamesLookupService.providerId,
        minInterval: Duration.zero,
      );
      final gate = GamesRequestGate(limiter: limiter);
      final slowKeys = configuredKeys();
      slowKeys.readDelay = const Duration(milliseconds: 120);
      final gamesTransport = FakeGamesTransport();
      final games = GamesLookupService(
        keys: slowKeys,
        transport: gamesTransport,
        gate: gate,
      );
      final metadata = MetadataService(
        providers: <MetadataProvider>[games],
        limiters: <String, ProviderRateLimiter>{
          GamesLookupService.providerId: limiter,
        },
      );

      final pending = metadata.lookup(query('045496367619'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      games.invalidateCredentials();
      final outcome = await pending;

      expect(outcome.candidates, isEmpty);
      expect(
        metadata.cooldownFor(GamesLookupService.providerId),
        Duration.zero,
        reason: 'a credential change is not a provider quota failure',
      );

      // Fresh credentials reach the provider immediately, with no penalty and no
      // stale cache entry in the way.
      slowKeys.readDelay = Duration.zero;
      gamesTransport
        ..enqueue(
          GamesEndpoint.scanDexLookup.key,
          scanDexMatch(
            gameId: 1,
            name: 'Game',
            platformId: 5,
            platformName: 'Wii',
          ),
        )
        ..enqueue(GamesEndpoint.twitchToken.key, twitchToken())
        ..enqueue(
          GamesEndpoint.igdbGames.key,
          igdbGame(
            id: 1,
            name: 'Game',
            platformIds: <int>[5],
            platformNames: <String, String>{'5': 'Wii'},
            releaseYears: <int, int>{5: 2009},
          ),
        );
      final fresh = await metadata.lookup(query('045496367619'));
      expect(fresh.candidates, isNotEmpty);
      expect(
        fresh.failures.where(
          (failure) =>
              failure.kind == LookupFailureKind.quota ||
              failure.kind == LookupFailureKind.cooldown,
        ),
        isEmpty,
      );
    },
  );

  group('routing', () {
    MetadataService metadataWith(StubMetadataProvider general) =>
        MetadataService(
          providers: <MetadataProvider>[service, general],
          cache: LookupCache(),
        );

    test(
      'a game hint runs games first and the general fallback only after',
      () async {
        enqueueWii();
        final general = StubMetadataProvider(
          id: 'upcitemdb',
          label: 'UPCitemdb',
          roles: const <ProviderRole>{ProviderRole.general},
        );
        final outcome = await metadataWith(
          general,
        ).lookup(query('045496367619'));
        expect(outcome.candidates.single.providerId, 'igdb');
        expect(general.calls, 0, reason: 'fallback only when games are empty');
      },
    );

    test(
      'an unknown non-ISBN code queries games before the fallback',
      () async {
        enqueueWii();
        final general = StubMetadataProvider(
          id: 'upcitemdb',
          label: 'UPCitemdb',
          roles: const <ProviderRole>{ProviderRole.general},
        );
        final outcome = await metadataWith(
          general,
        ).lookup(query('045496367619', medium: null));
        expect(outcome.queriedProviders, contains('igdb'));
        expect(outcome.candidates.single.providerId, 'igdb');
      },
    );

    test('book and ISBN lookups never reach the games provider', () async {
      final general = StubMetadataProvider(
        id: 'openlibrary',
        label: 'Open Library',
        roles: const <ProviderRole>{ProviderRole.books},
        candidates: <MetadataCandidate>[stubCandidate()],
      );
      final metadata = MetadataService(
        providers: <MetadataProvider>[service, general],
      );

      final book = await metadata.lookup(
        query('9780306406157', medium: MediaType.book),
      );
      expect(book.queriedProviders, isNot(contains('igdb')));
      expect(transport.calls, 0);

      final isbn = await metadata.lookup(query('9780306406157', medium: null));
      expect(isbn.queriedProviders, isNot(contains('igdb')));
      expect(transport.calls, 0);
    });
  });
}
