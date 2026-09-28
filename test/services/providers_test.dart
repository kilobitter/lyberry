import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/providers/musicbrainz_provider.dart';
import 'package:lyberry/services/providers/open_library_provider.dart';
import 'package:lyberry/services/providers/upcitemdb_provider.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/transport.dart';

import '../support/fake_transport.dart';
import '../support/test_support.dart';

LookupQuery queryFor(String code, {MediaType? hint}) => LookupQuery(
  identifier: IdentifierNormalizer.normalize(code),
  mediumHint: hint,
);

void main() {
  group('Open Library adapter', () {
    final editionUrl = 'https://openlibrary.org/isbn/9780306406157.json';
    final searchUrl =
        'https://openlibrary.org/search.json?isbn=9780306406157&'
        'fields=key%2Ctitle%2Cauthor_name%2Cfirst_publish_year%2Ccover_i%2C'
        'edition_key%2Cpublisher%2Cisbn&limit=10';

    test('prefers the edition year over the work first-publish year', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        editionUrl,
        body: jsonEncode(<String, Object?>{
          'key': '/books/OL1M',
          'title': 'Dune',
          'publishers': <String>['Chilton'],
          'publish_date': '1974',
          'covers': <int>[123],
        }),
      );
      transport.answer(
        searchUrl,
        body: jsonEncode(<String, Object?>{
          'docs': <Object?>[
            <String, Object?>{
              'key': '/works/OL1W',
              'title': 'Dune',
              'author_name': <String>['Frank Herbert'],
              'first_publish_year': 1965,
              'cover_i': 123,
              'isbn': <String>['9780306406157'],
              'publisher': <String>['Chilton'],
            },
          ],
        }),
      );

      final candidates = await OpenLibraryProvider(transport: transport)
          .lookup(queryFor('9780306406157', hint: MediaType.book))
          .then((result) => result.candidates);

      expect(candidates, hasLength(2));
      final edition = candidates.first;
      expect(edition.matchKind, MatchKind.exact);
      expect(edition.year, 1974);
      expect(edition.publisher, 'Chilton');
      expect(edition.coverUrl, contains('covers.openlibrary.org'));
      expect(edition.sourceUrl, contains('openlibrary.org/books/OL1M'));

      final work = candidates.last;
      expect(work.creator, 'Frank Herbert');
      expect(
        work.year,
        isNull,
        reason: 'first_publish_year must never become an edition year',
      );
    });

    test(
      'falls back to search rows when the ISBN edition is missing',
      () async {
        final transport = FakeHttpTransport();
        transport.answer(editionUrl, body: '{}', status: 404);
        transport.answer(
          searchUrl,
          body: jsonEncode(<String, Object?>{
            'docs': <Object?>[
              <String, Object?>{
                'key': '/works/OL9W',
                'title': 'Unknown printing',
                'author_name': <String>['Someone'],
              },
            ],
          }),
        );

        final candidates = await OpenLibraryProvider(
          transport: transport,
        ).lookup(queryFor('9780306406157')).then((result) => result.candidates);

        expect(candidates, hasLength(1));
        expect(candidates.single.matchKind, MatchKind.possible);
        expect(candidates.single.year, isNull);
      },
    );

    test('maps HTTP 429 to a quota failure with Retry-After', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        editionUrl,
        body: 'slow down',
        status: 429,
        headers: <String, String>{'Retry-After': '7'},
      );

      await expectLater(
        OpenLibraryProvider(
          transport: transport,
        ).lookup(queryFor('9780306406157')),
        throwsA(
          isA<ProviderException>()
              .having((error) => error.kind, 'kind', LookupFailureKind.quota)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              ),
        ),
      );
    });

    test('maps malformed JSON to a malformed failure', () async {
      final transport = FakeHttpTransport();
      transport.answer(editionUrl, body: '{not json');

      await expectLater(
        OpenLibraryProvider(
          transport: transport,
        ).lookup(queryFor('9780306406157')),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
      );
    });
  });

  group('MusicBrainz adapter', () {
    final releaseUrl =
        'https://musicbrainz.org/ws/2/release/?query=barcode%3A0724384654726&'
        'fmt=json&limit=10';

    test('parses a release, its format, year and cover art', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        releaseUrl,
        body: jsonEncode(<String, Object?>{
          'releases': <Object?>[
            <String, Object?>{
              'id': 'rel-1',
              'title': 'Mezzanine',
              'barcode': '0724384654726',
              'date': '1998-04-20',
              'artist-credit': <Object?>[
                <String, Object?>{'name': 'Massive Attack'},
              ],
              'label-info': <Object?>[
                <String, Object?>{
                  'label': <String, Object?>{'name': 'Virgin'},
                },
              ],
              'media': <Object?>[
                <String, Object?>{'format': '12" Vinyl'},
              ],
            },
          ],
        }),
      );

      final candidates =
          await MusicBrainzProvider(
                transport: transport,
                userAgent: 'Lyberry/0.2 (test)',
              )
              .lookup(queryFor('0724384654726', hint: MediaType.vinyl))
              .then((result) => result.candidates);

      final candidate = candidates.single;
      expect(candidate.matchKind, MatchKind.exact);
      expect(candidate.medium, MediaType.vinyl);
      expect(candidate.year, 1998);
      expect(candidate.creator, 'Massive Attack');
      expect(candidate.publisher, 'Virgin');
      expect(candidate.coverUrl, contains('coverartarchive.org'));
      expect(candidate.sourceUrl, contains('musicbrainz.org/release/rel-1'));
    });

    test('keeps fuzzy barcode hits as possible matches', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        releaseUrl,
        body: jsonEncode(<String, Object?>{
          'releases': <Object?>[
            <String, Object?>{
              'id': 'rel-2',
              'title': 'Something else',
              'barcode': '9999999999999',
            },
          ],
        }),
      );

      final candidates = await MusicBrainzProvider(
        transport: transport,
      ).lookup(queryFor('0724384654726')).then((result) => result.candidates);

      expect(candidates.single.matchKind, MatchKind.possible);
    });

    test('maps 503 with Retry-After to a quota failure', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        releaseUrl,
        body: 'busy',
        status: 503,
        headers: <String, String>{'Retry-After': '5'},
      );

      await expectLater(
        MusicBrainzProvider(
          transport: transport,
        ).lookup(queryFor('0724384654726')),
        throwsA(
          isA<ProviderException>()
              .having((error) => error.kind, 'kind', LookupFailureKind.quota)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 5),
              ),
        ),
      );
    });

    test('reports no match as an empty list, not an error', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        releaseUrl,
        body: jsonEncode(<String, Object?>{'releases': <Object?>[]}),
      );

      final result = await MusicBrainzProvider(
        transport: transport,
      ).lookup(queryFor('0724384654726'));
      expect(result.candidates, isEmpty);
    });
  });

  group('UPCitemdb adapter', () {
    final lookupUrl =
        'https://api.upcitemdb.com/prod/trial/lookup?upc=5051892202657';

    test('infers the medium and keeps the image URL', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        lookupUrl,
        body: jsonEncode(<String, Object?>{
          'code': 'OK',
          'items': <Object?>[
            <String, Object?>{
              'title': 'Blade Runner 2049 (Blu-ray)',
              'brand': 'Warner Bros.',
              'category': 'Movies & TV > Blu-ray',
              'images': <String>['https://i.ebayimg.com/images/cover.jpg'],
              'ean': '5051892202657',
            },
          ],
        }),
      );

      final candidates = await UpcItemDbProvider(
        transport: transport,
      ).lookup(queryFor('5051892202657')).then((result) => result.candidates);

      final candidate = candidates.single;
      expect(candidate.medium, MediaType.bluray);
      expect(candidate.creator, 'Warner Bros.');
      expect(candidate.coverUrl, contains('i.ebayimg.com'));
      expect(
        candidate.matchKind,
        MatchKind.exact,
        reason: 'the fixture ean is the queried code',
      );
    });

    test('maps a TOO_FAST body to a quota failure with reset delay', () async {
      // `X-RateLimit-Reset` is an absolute epoch timestamp, not a delay.
      final now = DateTime.utc(2026, 9, 24, 10);
      final clock = FixedClock(now);
      final transport = FakeHttpTransport();
      transport.answer(
        lookupUrl,
        body: jsonEncode(<String, Object?>{
          'code': 'TOO_FAST',
          'message': 'Please slow down',
        }),
        headers: <String, String>{
          'X-RateLimit-Reset':
              '${now.add(const Duration(seconds: 90)).millisecondsSinceEpoch ~/ 1000}',
        },
      );

      await expectLater(
        UpcItemDbProvider(
          transport: transport,
          clock: clock,
        ).lookup(queryFor('5051892202657')),
        throwsA(
          isA<ProviderException>()
              .having((error) => error.kind, 'kind', LookupFailureKind.quota)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 90),
              ),
        ),
      );

      // A stale epoch clamps to zero instead of a multi-decade wait.
      final staleTransport = FakeHttpTransport();
      staleTransport.answer(
        lookupUrl,
        body: jsonEncode(<String, Object?>{'code': 'TOO_FAST'}),
        headers: <String, String>{
          'X-RateLimit-Reset':
              '${now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000}',
        },
      );
      await expectLater(
        UpcItemDbProvider(
          transport: staleTransport,
          clock: clock,
        ).lookup(queryFor('5051892202657')),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.retryAfter,
            'retryAfter',
            Duration.zero,
          ),
        ),
      );
    });

    test('maps 429 to a quota failure', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        lookupUrl,
        body: '{}',
        status: 429,
        headers: <String, String>{'Retry-After': '60'},
      );

      await expectLater(
        UpcItemDbProvider(
          transport: transport,
        ).lookup(queryFor('5051892202657')),
        throwsA(
          isA<ProviderException>()
              .having((error) => error.kind, 'kind', LookupFailureKind.quota)
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 60),
              ),
        ),
      );
    });

    test('reports no items as an empty list', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        lookupUrl,
        body: jsonEncode(<String, Object?>{'code': 'OK', 'items': <Object?>[]}),
      );

      final result = await UpcItemDbProvider(
        transport: transport,
      ).lookup(queryFor('5051892202657'));
      expect(result.candidates, isEmpty);
    });

    test('surfaces transport timeouts as timeout failures', () async {
      final transport = FakeHttpTransport(
        failure: const TransportException(
          LookupFailureKind.timeout,
          'no answer',
        ),
      );

      await expectLater(
        UpcItemDbProvider(
          transport: transport,
        ).lookup(queryFor('5051892202657')),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.timeout,
          ),
        ),
      );
    });
  });

  group('metadata service', () {
    test('ranks exact matches first and keeps partial results', () async {
      final exact = _FakeProvider(
        id: 'probe',
        label: 'Probe',
        candidates: <MetadataCandidate>[
          _candidate('probe', 'exact-1', MatchKind.possible, 'Possible hit'),
          _candidate('probe', 'exact-2', MatchKind.exact, 'Exact hit'),
        ],
      );
      final failing = _FakeProvider(
        id: 'broken',
        label: 'Broken',
        failure: const ProviderException(LookupFailureKind.network, 'offline'),
      );

      final outcome = await MetadataService(
        providers: <MetadataProvider>[exact, failing],
      ).lookup(queryFor('9780306406157'));

      expect(outcome.candidates, hasLength(2));
      expect(outcome.candidates.first.title, 'Exact hit');
      expect(outcome.failures.single.providerId, 'broken');
      expect(outcome.allProvidersFailed, isFalse);
    });

    test('caches a completed lookup and skips the providers', () async {
      final provider = _FakeProvider(
        id: 'probe',
        label: 'Probe',
        candidates: <MetadataCandidate>[
          _candidate('probe', 'one', MatchKind.exact, 'Cached hit'),
        ],
      );
      final service = MetadataService(
        providers: <MetadataProvider>[provider],
        cache: LookupCache(clock: FixedClock(kBaseTime)),
      );

      final first = await service.lookup(queryFor('9780306406157'));
      final second = await service.lookup(queryFor('9780306406157'));

      expect(first.fromCache, isFalse);
      expect(second.fromCache, isTrue);
      expect(provider.calls, 1);
    });

    test('does not cache an all-provider failure', () async {
      final provider = _FakeProvider(
        id: 'probe',
        label: 'Probe',
        failure: const ProviderException(LookupFailureKind.http, '500'),
      );
      final service = MetadataService(
        providers: <MetadataProvider>[provider],
        cache: LookupCache(clock: FixedClock(kBaseTime)),
      );

      final outcome = await service.lookup(queryFor('9780306406157'));
      expect(outcome.allProvidersFailed, isTrue);

      await service.lookup(queryFor('9780306406157'));
      expect(provider.calls, 2, reason: 'failures must not be cached');
    });

    test('skips providers that do not support the medium hint', () async {
      final booksOnly = _FakeProvider(
        id: 'books',
        label: 'Books',
        mediaTypes: const <MediaType>{MediaType.book},
        candidates: <MetadataCandidate>[
          _candidate('books', 'one', MatchKind.exact, 'Book hit'),
        ],
      );
      final service = MetadataService(providers: <MetadataProvider>[booksOnly]);

      final vinylOutcome = await service.lookup(
        queryFor('0724384654726', hint: MediaType.vinyl),
      );
      expect(vinylOutcome.queriedProviders, isEmpty);
      expect(vinylOutcome.candidates, isEmpty);

      final bookOutcome = await service.lookup(
        queryFor('9780306406157', hint: MediaType.book),
      );
      expect(bookOutcome.candidates, hasLength(1));
    });
  });

  group('provider rate limiting', () {
    test('spaces calls and honours a server cooldown', () async {
      final limiter = ProviderRateLimiter(
        providerId: 'upcitemdb',
        minInterval: const Duration(milliseconds: 120),
      );

      final started = DateTime.now();
      await limiter.acquire();
      await limiter.acquire();
      final spaced = DateTime.now().difference(started);
      expect(spaced, greaterThanOrEqualTo(const Duration(milliseconds: 110)));

      limiter.penalize(const Duration(milliseconds: 150));
      expect(limiter.isCoolingDown, isTrue);

      final cooldownStart = DateTime.now();
      await limiter.acquire();
      expect(
        DateTime.now().difference(cooldownStart),
        greaterThanOrEqualTo(const Duration(milliseconds: 120)),
      );
    });
  });

  group('provider shape handling', () {
    final editionUrl = 'https://openlibrary.org/isbn/9780306406157.json';
    final searchUrl =
        'https://openlibrary.org/search.json?isbn=9780306406157&'
        'fields=key%2Ctitle%2Cauthor_name%2Cfirst_publish_year%2Ccover_i%2C'
        'edition_key%2Cpublisher%2Cisbn&limit=10';

    test('keeps the edition candidate when the search request fails', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        editionUrl,
        body: jsonEncode(<String, Object?>{
          'key': '/books/OL1M',
          'title': 'Dune',
          'publish_date': '1974',
        }),
      );
      transport.answer(searchUrl, body: 'boom', status: 500);

      final result = await OpenLibraryProvider(
        transport: transport,
      ).lookup(queryFor('9780306406157'));

      expect(result.candidates.single.title, 'Dune');
      expect(result.candidates.single.year, 1974);
      expect(result.warning, isNotNull);
      expect(result.warning!.kind, LookupFailureKind.http);
    });

    test('never presents an Open Library author id as a name', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        editionUrl,
        body: jsonEncode(<String, Object?>{
          'key': '/books/OL1M',
          'title': 'Dune',
          'publish_date': '1974',
          'authors': <Object?>[
            <String, Object?>{'key': '/authors/OL123A'},
          ],
        }),
      );
      transport.answer(
        searchUrl,
        body: jsonEncode(<String, Object?>{
          'docs': <Object?>[
            <String, Object?>{
              'key': '/works/OL1W',
              'title': 'Dune',
              'author_name': <String>['Frank Herbert'],
              'isbn': <String>['9780306406157'],
            },
          ],
        }),
      );

      final withSearch = await OpenLibraryProvider(
        transport: transport,
      ).lookup(queryFor('9780306406157'));
      final editionCandidate = withSearch.candidates.firstWhere(
        (candidate) => candidate.externalId == '/books/OL1M',
      );
      expect(editionCandidate.creator, 'Frank Herbert');
      expect(editionCandidate.creator, isNot(contains('/authors/')));

      // Without a usable search row the creator stays empty rather than showing
      // the identifier.
      final bareTransport = FakeHttpTransport();
      bareTransport.answer(
        editionUrl,
        body: jsonEncode(<String, Object?>{
          'title': 'Dune',
          'authors': <Object?>[
            <String, Object?>{'key': '/authors/OL123A'},
          ],
        }),
      );
      bareTransport.answer(
        searchUrl,
        body: jsonEncode(<String, Object?>{'docs': <Object?>[]}),
      );
      final bare = await OpenLibraryProvider(
        transport: bareTransport,
      ).lookup(queryFor('9780306406157'));
      expect(bare.candidates.single.creator, isEmpty);
    });

    test('uses the UPC description when the provider supplies one', () async {
      final transport = FakeHttpTransport();
      transport.answer(
        'https://api.upcitemdb.com/prod/trial/lookup?upc=5051892202657',
        body: jsonEncode(<String, Object?>{
          'code': 'OK',
          'items': <Object?>[
            <String, Object?>{
              'title': 'Blade Runner 2049',
              'brand': 'Warner Bros.',
              'category': 'Movies & TV',
              'description': 'A replicant hunt in a flooded Los Angeles.',
              'ean': '5051892202657',
            },
          ],
        }),
      );

      final result = await UpcItemDbProvider(
        transport: transport,
      ).lookup(queryFor('5051892202657'));

      expect(
        result.candidates.single.description,
        'A replicant hunt in a flooded Los Angeles.',
      );
    });

    test('malformed shapes are warnings or failures, not empty results', () async {
      // Open Library: a JSON array root is a hard failure.
      final arrayRoot = FakeHttpTransport();
      arrayRoot.answer(editionUrl, body: '[]');
      await expectLater(
        OpenLibraryProvider(
          transport: arrayRoot,
        ).lookup(queryFor('9780306406157')),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
      );

      // Open Library: a search body without `docs` is a warning, not a matchless
      // success, and a genuine empty list carries no warning.
      final missingDocs = FakeHttpTransport();
      missingDocs.answer(editionUrl, body: '{}', status: 404);
      missingDocs.answer(searchUrl, body: jsonEncode(<String, Object?>{}));
      final shape = await OpenLibraryProvider(
        transport: missingDocs,
      ).lookup(queryFor('9780306406157'));
      expect(shape.candidates, isEmpty);
      expect(shape.warning?.kind, LookupFailureKind.malformed);

      final emptyDocs = FakeHttpTransport();
      emptyDocs.answer(editionUrl, body: '{}', status: 404);
      emptyDocs.answer(
        searchUrl,
        body: jsonEncode(<String, Object?>{'docs': <Object?>[]}),
      );
      final empty = await OpenLibraryProvider(
        transport: emptyDocs,
      ).lookup(queryFor('9780306406157'));
      expect(empty.candidates, isEmpty);
      expect(empty.warning, isNull);

      // MusicBrainz: a root without `releases` is malformed, an empty release
      // list is a genuine no-match.
      final musicReleaseUrl =
          'https://musicbrainz.org/ws/2/release/?query=barcode%3A0724384654726&'
          'fmt=json&limit=10';
      final musicShape = FakeHttpTransport();
      musicShape.answer(musicReleaseUrl, body: jsonEncode(<String, Object?>{}));
      await expectLater(
        MusicBrainzProvider(
          transport: musicShape,
        ).lookup(queryFor('0724384654726')),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
      );

      final musicEmpty = FakeHttpTransport();
      musicEmpty.answer(
        musicReleaseUrl,
        body: jsonEncode(<String, Object?>{'releases': <Object?>[]}),
      );
      final musicResult = await MusicBrainzProvider(
        transport: musicEmpty,
      ).lookup(queryFor('0724384654726'));
      expect(musicResult.candidates, isEmpty);
      expect(musicResult.warning, isNull);

      // UPCitemdb: a response without an item list is malformed.
      final upcLookupUrl =
          'https://api.upcitemdb.com/prod/trial/lookup?upc=5051892202657';
      final upcShape = FakeHttpTransport();
      upcShape.answer(
        upcLookupUrl,
        body: jsonEncode(<String, Object?>{'code': 'OK'}),
      );
      await expectLater(
        UpcItemDbProvider(
          transport: upcShape,
        ).lookup(queryFor('5051892202657')),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
      );
    });

    test('equivalent identifier forms match exactly', () async {
      // MusicBrainz answers with the same ISBN written with hyphens.
      final musicUrl =
          'https://musicbrainz.org/ws/2/release/?query=barcode%3A9780306406157&'
          'fmt=json&limit=10';
      final musicTransport = FakeHttpTransport();
      musicTransport.answer(
        musicUrl,
        body: jsonEncode(<String, Object?>{
          'releases': <Object?>[
            <String, Object?>{
              'id': 'rel-9',
              'title': 'Dune audiobook',
              'barcode': '978-0-306-40615-7',
            },
          ],
        }),
      );
      final music = await MusicBrainzProvider(
        transport: musicTransport,
      ).lookup(queryFor('0306406152'));
      expect(music.candidates.single.matchKind, MatchKind.exact);

      // UPCitemdb answers with the zero-prefixed EAN of the queried UPC-A.
      final upcUrl =
          'https://api.upcitemdb.com/prod/trial/lookup?upc=0036000291452';
      final upcTransport = FakeHttpTransport();
      upcTransport.answer(
        upcUrl,
        body: jsonEncode(<String, Object?>{
          'code': 'OK',
          'items': <Object?>[
            <String, Object?>{
              'title': 'Some disc',
              'ean': '0036000291452',
              'upc': '036000291452',
            },
          ],
        }),
      );
      final upc = await UpcItemDbProvider(
        transport: upcTransport,
      ).lookup(queryFor('036000291452'));
      expect(upc.candidates.single.matchKind, MatchKind.exact);
    });
  });
}

class _FakeProvider implements MetadataProvider {
  _FakeProvider({
    required this.id,
    required this.label,
    this.candidates = const <MetadataCandidate>[],
    this.failure,
    this.mediaTypes = const <MediaType>{},
  });

  @override
  final String id;

  @override
  final String label;

  final List<MetadataCandidate> candidates;
  final ProviderException? failure;
  final Set<MediaType> mediaTypes;

  @override
  Set<ProviderRole> get roles => const <ProviderRole>{};
  int calls = 0;

  @override
  bool supports(MediaType? mediumHint) =>
      mediaTypes.isEmpty ||
      mediumHint == null ||
      mediaTypes.contains(mediumHint);

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    calls++;
    final problem = failure;
    if (problem != null) throw problem;
    return ProviderLookupResult(candidates: candidates);
  }
}

MetadataCandidate _candidate(
  String providerId,
  String externalId,
  MatchKind matchKind,
  String title,
) => MetadataCandidate(
  providerId: providerId,
  providerLabel: providerId,
  externalId: externalId,
  matchKind: matchKind,
  title: title,
  medium: MediaType.book,
);
