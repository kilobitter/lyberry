import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/movies/movies_lookup_service.dart';
import 'package:lyberry/services/movies/movies_request_gate.dart';
import 'package:lyberry/services/movies/movies_transport.dart';
import 'package:lyberry/services/providers/open_library_provider.dart';
import 'package:lyberry/services/providers/upcitemdb_provider.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/transport.dart';

import '../support/fake_movies.dart';
import '../support/fake_web.dart';
import '../support/fake_transport.dart';
import '../support/test_support.dart';

LookupQuery queryFor(String code, {MediaType? hint}) => LookupQuery(
  identifier: IdentifierNormalizer.normalize(code),
  mediumHint: hint,
);

MetadataCandidate candidateFor(
  String providerId,
  String externalId, {
  MatchKind matchKind = MatchKind.exact,
}) => MetadataCandidate(
  providerId: providerId,
  providerLabel: providerId,
  externalId: externalId,
  matchKind: matchKind,
  title: '$providerId hit',
  medium: MediaType.book,
);

/// A real UPCMDB service behind a scripted transport, so "no request" can be
/// asserted directly instead of inferred from routing metadata.
MoviesLookupService movieService(
  FakeMoviesTransport transport, {
  bool configured = true,
}) => MoviesLookupService(
  keys: configured
      ? InMemoryApiKeyStore(
          initial: <CredentialKey, String>{
            MovieKeyProvider.upcmdb: 'upcmdb-synthetic',
          },
        )
      : InMemoryApiKeyStore(),
  transport: transport,
  gate: MoviesRequestGate(
    limiter: ProviderRateLimiter(
      providerId: MoviesLookupService.providerId,
      minInterval: const Duration(milliseconds: 10),
    ),
  ),
);

/// Provider double with routing metadata, throttling and transient failures.
class _FakeProvider implements MetadataProvider {
  _FakeProvider({
    required this.id,
    this.roles = const <ProviderRole>{},
    this.candidates = const <MetadataCandidate>[],
    this.failuresRemaining = 0,
    this.limiter,
  });

  @override
  final String id;

  @override
  String get label => id;

  @override
  final Set<ProviderRole> roles;

  final List<MetadataCandidate> candidates;
  int failuresRemaining;
  final ProviderRateLimiter? limiter;

  int calls = 0;

  @override
  bool supports(MediaType? mediumHint) => true;

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    calls++;
    await limiter?.guard();
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const ProviderException(
        LookupFailureKind.network,
        'temporary glitch',
      );
    }
    return ProviderLookupResult(candidates: candidates);
  }
}

void main() {
  group('routing', () {
    test('an ISBN tries books first and only falls back when needed', () async {
      final books = _FakeProvider(
        id: 'books',
        roles: const <ProviderRole>{ProviderRole.books},
        candidates: <MetadataCandidate>[candidateFor('books', 'b1')],
      );
      final general = _FakeProvider(
        id: 'general',
        roles: const <ProviderRole>{ProviderRole.general},
        candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
      );

      final outcome = await MetadataService(
        providers: <MetadataProvider>[books, general],
      ).lookup(queryFor('9780306406157'));

      expect(outcome.candidates.single.providerId, 'books');
      expect(books.calls, 1);
      expect(general.calls, 0, reason: 'the fallback is only for no-match');
    });

    test('an ISBN falls back when the book catalogue has no match', () async {
      final books = _FakeProvider(
        id: 'books',
        roles: const <ProviderRole>{ProviderRole.books},
      );
      final general = _FakeProvider(
        id: 'general',
        roles: const <ProviderRole>{ProviderRole.general},
        candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
      );

      final outcome = await MetadataService(
        providers: <MetadataProvider>[books, general],
      ).lookup(queryFor('9780306406157'));

      expect(outcome.candidates.single.providerId, 'general');
      expect(books.calls, 1);
      expect(general.calls, 1);
    });

    test(
      'a non-ISBN code starts with music and not the book catalogue',
      () async {
        final books = _FakeProvider(
          id: 'books',
          roles: const <ProviderRole>{ProviderRole.books},
        );
        final music = _FakeProvider(
          id: 'music',
          roles: const <ProviderRole>{ProviderRole.music},
          candidates: <MetadataCandidate>[candidateFor('music', 'm1')],
        );
        final general = _FakeProvider(
          id: 'general',
          roles: const <ProviderRole>{ProviderRole.general},
        );

        final outcome = await MetadataService(
          providers: <MetadataProvider>[books, music, general],
        ).lookup(queryFor('0724384654726'));

        expect(outcome.candidates.single.providerId, 'music');
        expect(music.calls, 1);
        expect(books.calls, 0);
        expect(general.calls, 0);
      },
    );

    test('a DVD hint with no movie catalogue falls back to general', () async {
      final books = _FakeProvider(
        id: 'books',
        roles: const <ProviderRole>{ProviderRole.books},
      );
      final music = _FakeProvider(
        id: 'music',
        roles: const <ProviderRole>{ProviderRole.music},
      );
      final general = _FakeProvider(
        id: 'general',
        roles: const <ProviderRole>{ProviderRole.general},
        candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
      );

      final outcome = await MetadataService(
        providers: <MetadataProvider>[books, music, general],
      ).lookup(queryFor('5051892202657', hint: MediaType.dvd));

      expect(outcome.candidates.single.providerId, 'general');
      expect(general.calls, 1);
      // With no dedicated movie catalogue registered the primary stage is
      // empty, so the existing fallback stage runs as one group. These fakes
      // claim to support every hint; the real book/music providers filter a
      // DVD hint out through `supports()`.
      expect(books.calls, 1);
      expect(music.calls, 1);
    });

    test(
      'a DVD hint asks UPCMDB first and skips the general fallback',
      () async {
        final movieTransport = FakeMoviesTransport();
        movieTransport.enqueue(
          MoviesEndpoint.eanLookup.key,
          movieRecord(ean: '5051892202657', title: 'The Matrix', format: 'DVD'),
        );
        final general = _FakeProvider(
          id: 'general',
          roles: const <ProviderRole>{ProviderRole.general},
          candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
        );

        final outcome = await MetadataService(
          providers: <MetadataProvider>[movieService(movieTransport), general],
        ).lookup(queryFor('5051892202657', hint: MediaType.dvd));

        expect(outcome.candidates.single.providerId, 'upcmdb');
        expect(movieTransport.calls, 1);
        expect(movieTransport.paths.single, '/api/v1/lookup/ean/5051892202657');
        expect(general.calls, 0, reason: 'a movie hit needs no fallback');
      },
    );

    test('an unknown non-ISBN code asks UPCMDB before the fallback', () async {
      final movieTransport = FakeMoviesTransport();
      movieTransport.enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: '883929638482', title: 'The Matrix', format: 'DVD'),
      );
      final music = _FakeProvider(
        id: 'music',
        roles: const <ProviderRole>{ProviderRole.music},
      );
      final general = _FakeProvider(
        id: 'general',
        roles: const <ProviderRole>{ProviderRole.general},
        candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
      );

      final outcome = await MetadataService(
        providers: <MetadataProvider>[
          movieService(movieTransport),
          music,
          general,
        ],
      ).lookup(queryFor('883929638482'));

      expect(outcome.candidates.single.providerId, 'upcmdb');
      expect(general.calls, 0);
    });

    test(
      'a missing movie key still lets the existing providers answer',
      () async {
        final movieTransport = FakeMoviesTransport();
        final general = _FakeProvider(
          id: 'general',
          roles: const <ProviderRole>{ProviderRole.general},
          candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
        );

        final outcome = await MetadataService(
          providers: <MetadataProvider>[
            movieService(movieTransport, configured: false),
            general,
          ],
        ).lookup(queryFor('5051892202657', hint: MediaType.dvd));

        expect(outcome.candidates.single.providerId, 'general');
        expect(general.calls, 1);
        expect(movieTransport.calls, 0, reason: 'no key means no request');
        expect(
          outcome.failures,
          isEmpty,
          reason: 'a missing key is not a provider failure',
        );
      },
    );

    test('book, music, game and ISBN codes never reach UPCMDB', () async {
      final movieTransport = FakeMoviesTransport();
      final general = _FakeProvider(
        id: 'general',
        roles: const <ProviderRole>{ProviderRole.general},
      );
      final service = MetadataService(
        providers: <MetadataProvider>[movieService(movieTransport), general],
      );

      for (final hint in <MediaType>[
        MediaType.book,
        MediaType.cd,
        MediaType.vinyl,
        MediaType.game,
      ]) {
        await service.lookup(queryFor('5051892202657', hint: hint));
      }
      for (final hint in <MediaType?>[
        null,
        MediaType.book,
        MediaType.cd,
        MediaType.game,
        MediaType.dvd,
      ]) {
        await service.lookup(queryFor('9780306406157', hint: hint));
      }

      expect(movieTransport.calls, 0);
    });

    test('an EAN-8 never reaches UPCMDB and stays a clean no-match', () async {
      final movieTransport = FakeMoviesTransport();
      final general = _FakeProvider(
        id: 'general',
        roles: const <ProviderRole>{ProviderRole.general},
        candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
      );

      final outcome = await MetadataService(
        providers: <MetadataProvider>[movieService(movieTransport), general],
      ).lookup(queryFor('96385074'));

      expect(movieTransport.calls, 0);
      expect(outcome.candidates.single.providerId, 'general');
    });

    test('equivalent forms share one cache entry', () async {
      final books = _FakeProvider(
        id: 'books',
        roles: const <ProviderRole>{ProviderRole.books},
        candidates: <MetadataCandidate>[candidateFor('books', 'b1')],
      );
      final service = MetadataService(
        providers: <MetadataProvider>[books],
        cache: LookupCache(clock: FixedClock(kBaseTime)),
      );

      final isbn10 = await service.lookup(queryFor('0306406152'));
      final isbn13 = await service.lookup(queryFor('9780306406157'));

      expect(isbn10.fromCache, isFalse);
      expect(isbn13.fromCache, isTrue);
      expect(books.calls, 1);
    });
  });

  group('partial results and retry', () {
    test(
      'a partial lookup is not cached, so retry reaches the failed provider',
      () async {
        final books = _FakeProvider(
          id: 'books',
          roles: const <ProviderRole>{ProviderRole.books},
          candidates: <MetadataCandidate>[candidateFor('books', 'b1')],
        );
        final flaky = _FakeProvider(
          // No routing role: queried alongside the primary stage.
          id: 'flaky',
          candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
          failuresRemaining: 1,
        );
        final service = MetadataService(
          providers: <MetadataProvider>[books, flaky],
          cache: LookupCache(clock: FixedClock(kBaseTime)),
        );

        // First lookup: books answers, general is queried only because the primary
        // found nothing, and it fails transiently.
        final first = await service.lookup(queryFor('9780306406157'));
        expect(first.candidates.single.providerId, 'books');
        expect(first.failures, hasLength(1));
        expect(flaky.calls, 1);

        // Second lookup: not cached (a provider was lost), so the general provider
        // is reachable again and now succeeds.
        final second = await service.lookup(queryFor('9780306406157'));
        expect(second.candidates, hasLength(2));
        expect(second.failures, isEmpty);
        expect(flaky.calls, 2);

        // Third lookup: a clean answer is cached.
        final third = await service.lookup(queryFor('9780306406157'));
        expect(third.fromCache, isTrue);
        expect(flaky.calls, 2);
      },
    );

    test(
      'a cooling provider answers immediately without hiding other results',
      () async {
        final limiter = ProviderRateLimiter(
          providerId: 'general',
          minInterval: const Duration(seconds: 30),
          clock: FixedClock(kBaseTime),
        );
        // Consume the slot so the next guarded request is inside the spacing.
        await limiter.acquire();
        final cooling = _FakeProvider(
          // No routing role: queried alongside the primary stage.
          id: 'cooling',
          limiter: limiter,
          candidates: <MetadataCandidate>[candidateFor('general', 'g1')],
        );
        final books = _FakeProvider(
          id: 'books',
          roles: const <ProviderRole>{ProviderRole.books},
          candidates: <MetadataCandidate>[candidateFor('books', 'b1')],
        );
        final service = MetadataService(
          providers: <MetadataProvider>[books, cooling],
          limiters: <String, ProviderRateLimiter>{'cooling': limiter},
        );

        final started = DateTime.now();
        final outcome = await service.lookup(queryFor('9780306406157'));
        final elapsed = DateTime.now().difference(started);

        expect(outcome.candidates.single.providerId, 'books');
        expect(outcome.failures.single.kind, LookupFailureKind.cooldown);
        expect(
          elapsed,
          lessThan(const Duration(seconds: 2)),
          reason: 'a cooling provider must not hold the lookup open',
        );
      },
    );

    test('retry has a way to requery after a transient failure', () async {
      final flaky = _FakeProvider(
        id: 'books',
        roles: const <ProviderRole>{ProviderRole.books},
        candidates: <MetadataCandidate>[candidateFor('books', 'b1')],
        failuresRemaining: 1,
      );
      final service = MetadataService(
        providers: <MetadataProvider>[flaky],
        cache: LookupCache(clock: FixedClock(kBaseTime)),
      );

      final first = await service.lookup(queryFor('9780306406157'));
      expect(first.allProvidersFailed, isTrue);

      final second = await service.lookup(queryFor('9780306406157'));
      expect(second.candidates, hasLength(1));
      expect(flaky.calls, 2);
    });
  });

  group('rate limiting at the request boundary', () {
    test('Open Library spaces its edition and search requests', () async {
      final limiter = ProviderRateLimiter(
        providerId: 'openlibrary',
        minInterval: const Duration(milliseconds: 80),
      );
      final transport = FakeHttpTransport();
      transport.answer(
        'https://openlibrary.org/isbn/9780306406157.json',
        body: jsonEncode(<String, Object?>{'title': 'Dune'}),
      );
      transport.answer(
        'https://openlibrary.org/search.json?isbn=9780306406157&'
        'fields=key%2Ctitle%2Cauthor_name%2Cfirst_publish_year%2Ccover_i%2C'
        'edition_key%2Cpublisher%2Cisbn&limit=10',
        body: jsonEncode(<String, Object?>{'docs': <Object?>[]}),
      );

      final started = DateTime.now();
      final result = await OpenLibraryProvider(
        transport: transport,
        limiter: limiter,
      ).lookup(queryFor('9780306406157'));
      final elapsed = DateTime.now().difference(started);

      expect(transport.requests, hasLength(2));
      expect(result.candidates, hasLength(1));
      expect(
        elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 70)),
        reason: 'each HTTP request must respect the spacing rule',
      );
    });

    test(
      'a long spacing turns into a cooldown instead of a long wait',
      () async {
        final limiter = ProviderRateLimiter(
          providerId: 'upcitemdb',
          minInterval: const Duration(seconds: 30),
          clock: FixedClock(kBaseTime),
        );
        await limiter.acquire();
        final transport = FakeHttpTransport();
        transport.answer(
          'https://api.upcitemdb.com/prod/trial/lookup?upc=5051892202657',
          body: jsonEncode(<String, Object?>{
            'code': 'OK',
            'items': <Object?>[],
          }),
        );

        final started = DateTime.now();
        await expectLater(
          UpcItemDbProvider(
            transport: transport,
            limiter: limiter,
            clock: FixedClock(kBaseTime),
          ).lookup(queryFor('5051892202657')),
          throwsA(
            isA<ProviderException>().having(
              (error) => error.kind,
              'kind',
              LookupFailureKind.cooldown,
            ),
          ),
        );
        expect(
          DateTime.now().difference(started),
          lessThan(const Duration(seconds: 2)),
        );
        expect(transport.requests, isEmpty);
      },
    );

    test('two concurrent guarded calls do not both pass immediately', () async {
      final limiter = ProviderRateLimiter(
        providerId: 'musicbrainz',
        minInterval: const Duration(milliseconds: 90),
      );

      final started = DateTime.now();
      await Future.wait(<Future<Duration>>[
        limiter.acquire(),
        Future<void>.delayed(
          const Duration(milliseconds: 5),
        ).then((_) => limiter.acquire()),
      ]);
      final elapsed = DateTime.now().difference(started);
      expect(elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 80)));
    });
  });

  group('Retry-After parsing', () {
    test('parses delta seconds, HTTP dates and rejects junk', () {
      final clock = FixedClock(DateTime.utc(1994, 11, 6, 8, 49, 0));

      expect(
        parseRetryAfter('120', clock: clock),
        const Duration(seconds: 120),
      );
      expect(parseRetryAfter('-5', clock: clock), Duration.zero);
      expect(
        parseRetryAfter('Sun, 06 Nov 1994 08:49:37 GMT', clock: clock),
        const Duration(seconds: 37),
      );
      expect(parseRetryAfter('not a date', clock: clock), isNull);
      expect(parseRetryAfter(null, clock: clock), isNull);
    });

    test('a past HTTP date clamps to zero', () {
      final clock = FixedClock(DateTime.utc(2026, 9, 24, 10));
      expect(
        parseRetryAfter('Sun, 06 Nov 1994 08:49:37 GMT', clock: clock),
        Duration.zero,
      );
    });
  });
}
