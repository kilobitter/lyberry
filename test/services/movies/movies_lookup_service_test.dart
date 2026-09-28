import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/movies/movies_lookup_service.dart';
import 'package:lyberry/services/movies/movies_request_gate.dart';
import 'package:lyberry/services/movies/movies_transport.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/state/item_draft.dart';

import '../../support/fake_movies.dart';
import '../../support/fake_web.dart';

const String kUpc = '045496367619';
const String kEuropeanEan = '5051888100639';

void main() {
  late FakeMoviesTransport transport;
  late InMemoryApiKeyStore keys;
  late ProviderRateLimiter limiter;
  late MoviesRequestGate gate;
  late LookupCache cache;
  late MoviesLookupService service;

  InMemoryApiKeyStore configuredKeys() => InMemoryApiKeyStore(
    initial: <CredentialKey, String>{
      MovieKeyProvider.upcmdb: 'upcmdb-synthetic',
    },
  );

  void build({
    InMemoryApiKeyStore? keyStore,
    Duration minInterval = const Duration(milliseconds: 10),
    int maxConcurrent = 2,
    MoviesTransport? moviesTransport,
  }) {
    keys = keyStore ?? configuredKeys();
    cache = LookupCache();
    limiter = ProviderRateLimiter(
      providerId: MoviesLookupService.providerId,
      minInterval: minInterval,
    );
    gate = MoviesRequestGate(limiter: limiter, maxConcurrent: maxConcurrent);
    service = MoviesLookupService(
      keys: keys,
      transport: moviesTransport ?? transport,
      gate: gate,
      cache: cache,
    );
  }

  setUp(() {
    transport = FakeMoviesTransport();
    build();
  });

  LookupQuery query(String code, {MediaType? medium = MediaType.bluray}) =>
      LookupQuery(
        identifier: IdentifierNormalizer.normalize(code),
        mediumHint: medium,
      );

  FakeMoviesCall fullMetalJacket({Duration delay = Duration.zero}) =>
      FakeMoviesCall(
        statusCode: 200,
        delay: delay,
        json: <String, Object?>{
          'upc': '45496367619',
          'title': 'Full Metal Jacket',
          'year': 1987,
          'format': '4K UHD + Blu-ray',
          'special_features': '4K Ultra HD + Blu-ray (Repackaged)',
          'publisher': 'Warner Home Video',
          'imdbID': 'tt0093058',
          'plot': 'A pragmatic U.S. Marine observes the dehumanizing effects.',
          'runtime': '116 min',
          'genre': 'Drama, War',
          'director': 'Stanley Kubrick',
          'actors': 'Matthew Modine, R. Lee Ermey',
          'imdbRating': 8.2,
          'rated': 'R',
          'productImageUrl': 'https://m.media-amazon.com/images/I/fmj.jpg',
        },
      );

  test('maps a documented record onto an editable movie candidate', () async {
    transport.enqueue(MoviesEndpoint.upcLookup.key, fullMetalJacket());

    final result = await service.lookup(query(kUpc));

    expect(transport.calls, 1);
    expect(transport.paths, <String>['/api/v1/lookup/045496367619']);
    expect(transport.apiKeys, <String>['upcmdb-synthetic']);

    final candidate = result.candidates.single;
    expect(candidate.providerId, 'upcmdb');
    expect(candidate.providerLabel, 'UPCMDB');
    expect(candidate.title, 'Full Metal Jacket');
    expect(candidate.creator, 'Stanley Kubrick');
    expect(candidate.year, 1987);
    expect(candidate.publisher, 'Warner Home Video');
    expect(candidate.medium, MediaType.bluray);
    expect(candidate.matchKind, MatchKind.exact);
    expect(candidate.format, '4K UHD + Blu-ray');
    expect(candidate.coverUrl, 'https://m.media-amazon.com/images/I/fmj.jpg');
    expect(candidate.sourceUrl, 'https://www.imdb.com/title/tt0093058/');
    expect(candidate.externalId, startsWith('upcmdb:code:45496367619|'));
    expect(candidate.edition, '4K Ultra HD + Blu-ray (Repackaged)');
    // The 4K/edition text is retained, and the external rating is labelled.
    expect(candidate.description, contains('Format: 4K UHD + Blu-ray'));
    expect(
      candidate.description,
      contains('Edition: 4K Ultra HD + Blu-ray (Repackaged)'),
    );
    expect(candidate.description, contains('Runtime: 116 min'));
    expect(candidate.description, contains('Genre: Drama, War'));
    expect(
      candidate.description,
      contains('Cast: Matthew Modine, R. Lee Ermey'),
    );
    expect(candidate.description, contains('IMDb rating: 8.2/10 (external)'));

    // The external rating, the plot and the cast never touch the personal
    // rating, review or notes, and a movie draft has no stray platform.
    final draft = ItemDraft.fromCandidate(candidate, barcode: kUpc);
    expect(draft.rating, isNull);
    expect(draft.review, isEmpty);
    expect(draft.notes, isEmpty);
    expect(draft.barcode, kUpc);
    expect(draft.platform, isEmpty);
    expect(draft.medium, MediaType.bluray);
    expect(draft.source?.providerId, 'upcmdb');
  });

  test(
    'maps DVD, Blu-ray, 4K and unknown formats without inventing one',
    () async {
      transport
        ..enqueue(
          MoviesEndpoint.eanLookup.key,
          movieRecord(ean: kEuropeanEan, title: 'DVD Film', format: 'DVD'),
        )
        ..enqueue(
          MoviesEndpoint.eanLookup.key,
          movieRecord(ean: kEuropeanEan, title: 'BD Film', format: 'BD'),
        )
        ..enqueue(
          MoviesEndpoint.eanLookup.key,
          movieRecord(ean: kEuropeanEan, title: 'Plain Film'),
        )
        ..enqueue(
          MoviesEndpoint.eanLookup.key,
          movieRecord(
            ean: kEuropeanEan,
            title: 'Hinted Film',
            specialFeatures: 'Repackaged',
          ),
        );

      final dvd = await service.lookup(
        query(kEuropeanEan, medium: MediaType.bluray),
      );
      expect(dvd.candidates.single.medium, MediaType.dvd);
      expect(dvd.candidates.single.format, 'DVD');

      final bd = await service.lookup(
        query(kEuropeanEan, medium: MediaType.dvd),
      );
      expect(bd.candidates.single.medium, MediaType.bluray);
      expect(bd.candidates.single.format, 'BD');

      // No format in the record and no hint: the medium stays unspecified and
      // editable rather than being guessed.
      final plain = await service.lookup(query(kEuropeanEan, medium: null));
      expect(plain.candidates.single.medium, isNull);
      expect(plain.candidates.single.format, isEmpty);

      // The supplied hint decides when the record itself names no format.
      final hinted = await service.lookup(
        query(kEuropeanEan, medium: MediaType.dvd),
      );
      expect(hinted.candidates.single.medium, MediaType.dvd);
      expect(hinted.candidates.single.format, 'Repackaged');
    },
  );

  test('a malformed IMDb id falls back to the public page', () async {
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      movieRecord(
        upc: '45496367619',
        title: 'Full Metal Jacket',
        format: 'DVD',
        imdbId: 'tt12',
      ),
    );

    final candidate = (await service.lookup(query(kUpc))).candidates.single;

    expect(candidate.sourceUrl, 'https://upcmdb.com/');
    // The supplier code is the identity, so a malformed id never leaks in.
    expect(candidate.externalId, 'upcmdb:code:45496367619|dvd');
  });

  test(
    'identity falls back to title and year when no code or id exists',
    () async {
      transport.enqueue(
        MoviesEndpoint.titleSearch.key,
        movieSearch(<Object?>[
          <String, Object?>{
            'title': 'The Matrix',
            'year': 1999,
            'format': 'DVD',
            'imdbID': 'tt0133093',
          },
          <String, Object?>{'title': 'No Ids', 'year': 2001, 'format': 'DVD'},
        ]),
      );

      final outcome = await service.searchByTitle('Matrix');

      expect(outcome.candidates.first.externalId, 'upcmdb:imdb:tt0133093|dvd');
      expect(
        outcome.candidates.last.externalId,
        'upcmdb:title:no ids:2001|dvd',
      );
    },
  );

  test(
    'editions without codes stay separate and identical rows dedupe',
    () async {
      transport.enqueue(
        MoviesEndpoint.titleSearch.key,
        movieSearch(<Object?>[
          <String, Object?>{
            'title': 'The Matrix',
            'year': 1999,
            'format': 'Blu-ray',
            'imdbID': 'tt0133093',
            'special_features': 'Blu-ray (Repackaged)',
            'publisher': 'Warner Home Video',
          },
          <String, Object?>{
            'title': 'The Matrix',
            'year': 1999,
            'format': 'Blu-ray',
            'imdbID': 'tt0133093',
            'special_features': '4K Ultra HD + Blu-ray',
            'publisher': 'Warner Bros.',
          },
          <String, Object?>{
            // Exact duplicate of the first row: one candidate only.
            'title': 'The Matrix',
            'year': 1999,
            'format': 'Blu-ray',
            'imdbID': 'tt0133093',
            'special_features': 'Blu-ray (Repackaged)',
            'publisher': 'Warner Home Video',
          },
        ]),
      );

      final outcome = await service.searchByTitle('The Matrix');

      expect(outcome.candidates, hasLength(2));
      expect(outcome.candidates.map((c) => c.externalId).toSet(), hasLength(2));
      expect(outcome.candidates.map((c) => c.edition).toSet(), <String>{
        'Blu-ray (Repackaged)',
        '4K Ultra HD + Blu-ray',
      });
    },
  );

  test('only downloadable cover URLs are kept on a candidate', () async {
    Future<String?> coverFor(String url) async {
      cache.clear();
      transport.enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(
          upc: '45496367619',
          title: 'Full Metal Jacket',
          format: 'DVD',
          productImageUrl: url,
        ),
      );
      final candidate = (await service.lookup(query(kUpc))).candidates.single;
      return candidate.coverUrl;
    }

    expect(
      await coverFor('https://m.media-amazon.com/images/I/x.jpg'),
      'https://m.media-amazon.com/images/I/x.jpg',
    );
    for (final rejected in <String>[
      'http://m.media-amazon.com/images/I/x.jpg',
      'https://user:pass@m.media-amazon.com/images/I/x.jpg',
      'https://127.0.0.1/x.jpg',
      'https://images.example.test/x.jpg',
      'https://m.media-amazon.com:8443/x.jpg',
      'not a url',
    ]) {
      expect(await coverFor(rejected), isNull, reason: rejected);
    }
  });

  test(
    'editions of one film stay separate candidates and dedupe exactly',
    () async {
      transport.enqueue(
        MoviesEndpoint.titleSearch.key,
        movieSearch(<Object?>[
          <String, Object?>{
            'upc': '883929638482',
            'title': 'The Matrix',
            'year': 1999,
            'format': 'DVD',
            'imdbID': 'tt0133093',
          },
          <String, Object?>{
            'upc': '883929638499',
            'title': 'The Matrix',
            'year': 1999,
            'format': '4K UHD + Blu-ray',
            'imdbID': 'tt0133093',
          },
          <String, Object?>{
            'upc': '883929638499',
            'title': 'The Matrix',
            'year': 1999,
            'format': '4K UHD + Blu-ray',
            'imdbID': 'tt0133093',
          },
        ]),
      );

      final outcome = await service.searchByTitle('The Matrix');

      expect(outcome.candidates, hasLength(2));
      expect(outcome.candidates.map((c) => c.externalId).toSet(), hasLength(2));
      expect(
        outcome.candidates.every((c) => c.matchKind == MatchKind.possible),
        isTrue,
      );
    },
  );

  test('bounds a long title search to unique candidates', () async {
    transport.enqueue(
      MoviesEndpoint.titleSearch.key,
      movieSearch(<Object?>[
        for (var index = 0; index < 40; index++)
          <String, Object?>{
            'upc': '88392963848$index',
            'title': 'Film $index',
            'format': 'DVD',
          },
      ]),
    );

    final outcome = await service.searchByTitle('Film');

    expect(
      outcome.candidates,
      hasLength(MoviesLookupService.maxMovieCandidates),
    );
  });

  test('a missing key is a clean empty answer for every hint', () async {
    build(keyStore: InMemoryApiKeyStore());

    expect(await service.isConfigured, isFalse);

    // No key means no request and a clean empty result for every hint,
    // including an explicit movie hint, so the existing providers and the
    // general fallback answer a barcode normally with no spurious UPCMDB
    // failure. Setup guidance belongs to the explicit title search.
    for (final hint in <MediaType?>[MediaType.dvd, MediaType.bluray, null]) {
      final empty = await service.lookup(query(kUpc, medium: hint));
      expect(empty.candidates, isEmpty, reason: 'hint $hint');
      expect(empty.warning, isNull, reason: 'hint $hint');
    }

    final outcome = await service.searchByTitle('Alien');
    expect(outcome.candidates, isEmpty);
    expect(outcome.failure?.kind, LookupFailureKind.unavailable);
    expect(outcome.failure?.message, contains('Settings'));

    // No request was made for any of these.
    expect(transport.calls, 0);
  });

  test('an unreadable key is a typed failure, not a no-match', () async {
    keys.readFailure = const WebLookupException(
      WebFailureKind.unavailable,
      'UPCMDB API key could not be read on this device.',
      stage: WebLookupStage.keys,
    );

    await expectLater(service.isConfigured, throwsA(isA<ProviderException>()));
    await expectLater(
      service.lookup(query(kUpc, medium: MediaType.dvd)),
      throwsA(
        isA<ProviderException>()
            .having((e) => e.kind, 'kind', LookupFailureKind.unavailable)
            .having((e) => e.message, 'message', contains('could not be read')),
      ),
    );
    final outcome = await service.searchByTitle('Alien');
    expect(outcome.failure?.kind, LookupFailureKind.unavailable);
    expect(outcome.failure?.message, contains('could not be read'));
    expect(transport.calls, 0);
  });

  test('a key removed during the read starts no request', () async {
    keys.readDelay = const Duration(milliseconds: 60);
    transport.enqueue(MoviesEndpoint.upcLookup.key, fullMetalJacket());

    final pending = service.lookup(query(kUpc));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    service.invalidateCredentials();

    await expectLater(
      pending,
      throwsA(
        isA<ProviderException>()
            .having((e) => e.kind, 'kind', LookupFailureKind.unavailable)
            .having((e) => e.message, 'message', contains('changed')),
      ),
    );
    expect(transport.calls, 0);
  });

  test('a request queued behind a slot never sends a removed key', () async {
    build(maxConcurrent: 1);
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      fullMetalJacket(delay: const Duration(milliseconds: 80)),
    );

    final first = service.lookup(query(kUpc));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // This call cannot be admitted until the first one releases its slot.
    final queued = service.lookup(query(kUpc, medium: MediaType.dvd));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    service.invalidateCredentials();

    await expectLater(first, throwsA(isA<ProviderException>()));
    await expectLater(
      queued,
      throwsA(
        isA<ProviderException>()
            .having((e) => e.kind, 'kind', LookupFailureKind.unavailable)
            .having((e) => e.message, 'message', contains('changed')),
      ),
    );
    // Only the already-sent request reached the transport.
    expect(transport.calls, 1);
  });

  test(
    'a request waiting on the spacing rule never sends a removed key',
    () async {
      build(minInterval: const Duration(milliseconds: 200));
      transport.enqueue(MoviesEndpoint.upcLookup.key, fullMetalJacket());

      final first = await service.lookup(query(kUpc));
      expect(first.candidates, hasLength(1));
      expect(transport.calls, 1);

      // The next call waits inside the limiter's spacing rule; the key is removed
      // while it waits, so it must not be sent.
      final pending = service.lookup(query(kUpc, medium: MediaType.dvd));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      service.invalidateCredentials();

      await expectLater(
        pending,
        throwsA(
          isA<ProviderException>()
              .having((e) => e.kind, 'kind', LookupFailureKind.unavailable)
              .having((e) => e.message, 'message', contains('changed')),
        ),
      );
      expect(transport.calls, 1);
    },
  );

  test(
    'a title search queued behind a slot never sends a removed key',
    () async {
      final blocked = Completer<void>();
      final inner = FakeMoviesTransport();
      final blocking = _BlockingMoviesTransport(gate: blocked, inner: inner);
      build(maxConcurrent: 1, moviesTransport: blocking);
      inner.enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: '45496367619', title: 'Full Metal Jacket'),
      );

      // The barcode call takes the only slot and is held at an explicit
      // boundary inside the transport.
      final first = service.lookup(query(kUpc));
      await pumpEventQueue();
      expect(blocking.entered, 1);

      // The title search cannot be admitted yet.
      final second = service.searchByTitle('The Matrix');
      await pumpEventQueue();
      expect(blocking.entered, 1);

      service.invalidateCredentials();
      blocked.complete();

      // The in-flight barcode answer is not published, and the queued title
      // search is rejected after admission without reaching the transport.
      await expectLater(first, throwsA(isA<ProviderException>()));
      final outcome = await second;
      expect(outcome.candidates, isEmpty);
      expect(outcome.failure?.kind, LookupFailureKind.unavailable);
      expect(blocking.entered, 1);
      expect(inner.calls, 1);
    },
  );

  test(
    'an answer that arrives after a key change is never published',
    () async {
      transport.enqueue(
        MoviesEndpoint.upcLookup.key,
        fullMetalJacket(delay: const Duration(milliseconds: 60)),
      );

      final pending = service.lookup(query(kUpc));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.invalidateCredentials();

      await expectLater(
        pending,
        throwsA(
          isA<ProviderException>().having(
            (e) => e.kind,
            'kind',
            LookupFailureKind.unavailable,
          ),
        ),
      );
    },
  );

  test(
    'a title search invalidated in flight returns a failure, not candidates',
    () async {
      transport.enqueue(
        MoviesEndpoint.titleSearch.key,
        FakeMoviesCall(
          statusCode: 200,
          delay: const Duration(milliseconds: 60),
          json: <Object?>[
            <String, Object?>{'title': 'Alien', 'format': 'DVD'},
          ],
        ),
      );

      final pending = service.searchByTitle('Alien');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      service.invalidateCredentials();

      final outcome = await pending;
      expect(outcome.candidates, isEmpty);
      expect(outcome.failure?.kind, LookupFailureKind.unavailable);
    },
  );

  test('a credential abort does not penalize the shared quota and a fresh '
      'lookup still works', () async {
    final metadata = MetadataService(
      providers: <MetadataProvider>[service],
      limiters: <String, ProviderRateLimiter>{
        MoviesLookupService.providerId: limiter,
      },
      cache: cache,
    );
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      fullMetalJacket(delay: const Duration(milliseconds: 60)),
    );

    final pending = metadata.lookup(query(kUpc));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    service.invalidateCredentials();

    final aborted = await pending;
    expect(aborted.candidates, isEmpty);
    expect(aborted.failures.single.kind, LookupFailureKind.unavailable);
    // A credential change must not look like a provider quota failure.
    expect(metadata.cooldownFor(MoviesLookupService.providerId), Duration.zero);

    // The next lookup is not held back by a stale penalty.
    transport.enqueue(MoviesEndpoint.upcLookup.key, fullMetalJacket());
    final fresh = await metadata.lookup(query(kUpc));
    expect(fresh.candidates.single.title, 'Full Metal Jacket');
  });

  test('a 429 cooldown is shared by the barcode and title paths', () async {
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      movieStatus(429, headers: <String, String>{'retry-after': '30'}),
    );

    await expectLater(
      service.lookup(query(kUpc)),
      throwsA(
        isA<ProviderException>()
            .having((e) => e.kind, 'kind', LookupFailureKind.quota)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 30),
            ),
      ),
    );
    expect(limiter.cooldownRemaining, greaterThan(const Duration(seconds: 20)));

    final outcome = await service.searchByTitle('Alien');
    expect(outcome.candidates, isEmpty);
    expect(outcome.failure?.kind, LookupFailureKind.cooldown);
    // No hidden retry and no second request while cooling down.
    expect(transport.calls, 1);
  });

  test('a 429 without Retry-After still parks the shared gate', () async {
    transport.enqueue(MoviesEndpoint.upcLookup.key, movieStatus(429));

    await expectLater(
      service.lookup(query(kUpc)),
      throwsA(isA<ProviderException>()),
    );
    expect(limiter.cooldownRemaining, greaterThan(const Duration(seconds: 30)));

    final outcome = await service.searchByTitle('Alien');
    expect(outcome.failure?.kind, LookupFailureKind.cooldown);
    expect(transport.calls, 1);
  });

  test('invalidating the key drops cached answers', () async {
    transport.enqueue(MoviesEndpoint.upcLookup.key, fullMetalJacket());
    final first = await service.lookup(query(kUpc));
    expect(first.candidates, hasLength(1));

    service.invalidateCredentials();
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      movieRecord(upc: '45496367619', title: 'Replaced', format: 'DVD'),
    );
    final second = await service.lookup(query(kUpc));

    expect(transport.calls, 2);
    expect(second.candidates.single.title, 'Replaced');
  });
}

/// Transport that records entry and then blocks on an explicit completer, so a
/// test can hold one request open without relying on wall-clock timing.
class _BlockingMoviesTransport implements MoviesTransport {
  _BlockingMoviesTransport({required this.gate, required this.inner});

  final Completer<void> gate;
  final FakeMoviesTransport inner;
  int entered = 0;

  @override
  Future<MoviesResponse> get(
    MoviesRequest request, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    entered++;
    await gate.future;
    return inner.get(request, timeout: timeout, maxBytes: maxBytes);
  }
}
