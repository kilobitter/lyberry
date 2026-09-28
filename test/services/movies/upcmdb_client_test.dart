import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/movies/movies_transport.dart';
import 'package:lyberry/services/movies/upcmdb_client.dart';

import '../../support/fake_movies.dart';

/// A real, checksum-valid UPC with a leading zero that the API documentation's
/// own sample omits (`85391163114`), plus its EAN-13 form.
const String kUpc = '045496367619';
const String kUpcEanForm = '0045496367619';

/// A European EAN-13 that must never be truncated to 12 digits.
const String kEuropeanEan = '5051888100639';

void main() {
  late FakeMoviesTransport transport;

  setUp(() => transport = FakeMoviesTransport());

  UpcMdbClient client({String key = 'upcmdb-synthetic'}) =>
      UpcMdbClient(transport: transport, apiKey: key);

  NormalizedIdentifier id(String code) => IdentifierNormalizer.normalize(code);

  test(
    'looks a UPC up on the UPC route and keeps the code in the path',
    () async {
      transport.enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(
          upc: '45496367619',
          title: 'Full Metal Jacket',
          year: 1987,
          format: 'DVD',
          publisher: 'Warner Home Video',
          imdbId: 'tt0093058',
          plot: 'A pragmatic U.S. Marine observes the dehumanizing effects...',
          runtime: '116 min',
          genre: 'Drama, War',
          director: 'Stanley Kubrick',
          actors: 'Matthew Modine',
          imdbRating: 8.2,
          rated: 'R',
          productImageUrl: 'https://images.example.test/fmj.jpg',
        ),
      );

      final matches = await client().lookupCode(id(kUpc));

      expect(transport.calls, 1);
      final request = transport.requestAt(0);
      expect(request.uri.path, '/api/v1/lookup/045496367619');
      expect(request.uri.query, isEmpty);
      // The key travels only in the raw header, never in the URL.
      expect(request.headers['x-api-key'], 'upcmdb-synthetic');
      expect(request.uri.toString(), isNot(contains('upcmdb-synthetic')));

      expect(matches, hasLength(1));
      expect(matches.single.codeVerified, isTrue);
      expect(matches.single.record.title, 'Full Metal Jacket');
      expect(matches.single.record.year, 1987);
      expect(matches.single.record.imdbRating, 8.2);
    },
  );

  test('a UPC and its leading-zero EAN-13 are one request, not two', () async {
    transport
      ..enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: '45496367619', title: 'Full Metal Jacket'),
      )
      ..enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: '45496367619', title: 'Full Metal Jacket'),
      );

    await client().lookupCode(id(kUpc));
    await client().lookupCode(id(kUpcEanForm));

    expect(transport.paths, <String>[
      '/api/v1/lookup/045496367619',
      '/api/v1/lookup/045496367619',
    ]);
    expect(transport.endpoints, everyElement(MoviesEndpoint.upcLookup.key));
  });

  test('a European EAN-13 uses the EAN route unchanged', () async {
    transport.enqueue(
      MoviesEndpoint.eanLookup.key,
      movieRecord(ean: kEuropeanEan, title: 'The Matrix', format: 'Blu-ray'),
    );

    final matches = await client().lookupCode(id(kEuropeanEan));

    expect(transport.paths, <String>['/api/v1/lookup/ean/5051888100639']);
    expect(matches.single.codeVerified, isTrue);
  });

  test('ISBN and EAN-8 codes never produce a request', () async {
    expect(await client().lookupCode(id('9780306406157')), isEmpty);
    expect(await client().lookupCode(id('96385074')), isEmpty);
    expect(transport.calls, 0);
  });

  test(
    'a record without code evidence is a possible match, never exact',
    () async {
      transport.enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(title: 'Some Film', format: 'DVD'),
      );

      final matches = await client().lookupCode(id(kUpc));

      expect(matches, hasLength(1));
      expect(matches.single.codeVerified, isFalse);
    },
  );

  test('surrounding whitespace is tolerated but other text is not', () async {
    transport
      ..enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: ' 45496367619 ', title: 'Full Metal Jacket'),
      )
      ..enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: 'UPC 045496367619', title: 'Full Metal Jacket'),
      )
      ..enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: '045496367619-x', title: 'Full Metal Jacket'),
      )
      ..enqueue(
        MoviesEndpoint.upcLookup.key,
        movieRecord(upc: '04.5496.367619', title: 'Full Metal Jacket'),
      );

    final padded = await client().lookupCode(id(kUpc));
    expect(padded.single.codeVerified, isTrue);

    for (final label in <String>['prefixed', 'suffixed', 'punctuated']) {
      await expectLater(
        client().lookupCode(id(kUpc)),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
        reason: label,
      );
    }
  });

  test('code equivalence validates checksum and length, not just digits', () {
    // Valid true UPC/EAN forms, including the documented short numeric UPC and
    // the UPC-12 / leading-zero EAN-13 pair.
    expect(codesAreEquivalent(kUpc, kUpc), isTrue);
    expect(codesAreEquivalent(kUpc, kUpcEanForm), isTrue);
    expect(codesAreEquivalent(kUpcEanForm, kUpc), isTrue);
    expect(codesAreEquivalent(kEuropeanEan, kEuropeanEan), isTrue);
    expect(codesAreEquivalent('45496367619', kUpc), isTrue);
    expect(codesAreEquivalent('45496367619', '45496367619'), isTrue);

    // Textually identical but unusable codes are never a match.
    for (final invalid in <String>[
      '045496367618', // equal, wrong UPC check digit
      '0045496367618', // equal, wrong leading-zero EAN-13 check digit
      '5051888100638', // equal, wrong EAN-13 check digit
      '12345678901234', // overlong
      '1234567', // too short
      '12345678901234567890', // far too long
    ]) {
      expect(codesAreEquivalent(invalid, invalid), isFalse, reason: invalid);
    }

    // A European EAN-13 is never equivalent to a shorter UPC-shaped value.
    expect(codesAreEquivalent(kEuropeanEan, '051888100639'), isFalse);
    expect(codesAreEquivalent('UPC 045496367619', kUpc), isFalse);
  });

  test('an explicitly mismatched record is rejected', () async {
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      movieRecord(upc: '883929638482', title: 'Another Film'),
    );

    await expectLater(
      client().lookupCode(id(kUpc)),
      throwsA(
        isA<ProviderException>()
            .having((e) => e.kind, 'kind', LookupFailureKind.malformed)
            .having((e) => e.message, 'message', contains('different code')),
      ),
    );
  });

  test('a mismatched row is ignored when a matching row is present', () async {
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      movieSearch(<Object?>[
        <String, Object?>{'upc': '883929638482', 'title': 'Another Film'},
        <String, Object?>{
          'upc': '45496367619',
          'title': 'Full Metal Jacket',
          'format': 'DVD',
        },
      ]),
    );

    final matches = await client().lookupCode(id(kUpc));

    expect(matches, hasLength(1));
    expect(matches.single.record.title, 'Full Metal Jacket');
    expect(matches.single.codeVerified, isTrue);
  });

  test('accepts the documented {status, data} envelope', () async {
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      movieWrapped(<String, Object?>{
        'upc': '45496367619',
        'title': 'Full Metal Jacket',
      }),
    );

    final matches = await client().lookupCode(id(kUpc));

    expect(matches.single.record.title, 'Full Metal Jacket');
    expect(matches.single.codeVerified, isTrue);
  });

  test('an error envelope is a typed failure, not a silent no-match', () async {
    transport.enqueue(
      MoviesEndpoint.upcLookup.key,
      movieWrapped(<String, Object?>{}, status: 'error'),
    );

    await expectLater(
      client().lookupCode(id(kUpc)),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.kind,
          'kind',
          LookupFailureKind.malformed,
        ),
      ),
    );
  });

  test('a 404 is a clean no-match', () async {
    transport.enqueue(MoviesEndpoint.upcLookup.key, movieNotFound());

    expect(await client().lookupCode(id(kUpc)), isEmpty);
  });

  test(
    'titles and the optional year are encoded on the search route',
    () async {
      transport.enqueue(
        MoviesEndpoint.titleSearch.key,
        movieSearch(<Object?>[
          <String, Object?>{
            'upc': '883929638482',
            'title': 'Blade Runner',
            'year': 1982,
            'format': 'Blu-ray',
          },
          <String, Object?>{
            'title': 'Blade Runner 2049',
            'year': 2017,
            'format': '4K UHD',
          },
        ]),
      );

      final records = await client().searchByTitle(
        'Blade Runner & More',
        year: 1982,
      );

      expect(transport.calls, 1);
      final uri = transport.requestAt(0).uri;
      expect(uri.path, '/api/v1/search');
      expect(uri.queryParameters, <String, String>{
        'title': 'Blade Runner & More',
        'year': '1982',
      });
      expect(records, hasLength(2));
      expect(records.last.title, 'Blade Runner 2049');
    },
  );

  test('a search without a year sends only the title', () async {
    transport.enqueue(
      MoviesEndpoint.titleSearch.key,
      movieSearch(<Object?>[
        <String, Object?>{'title': 'Alien', 'format': 'DVD'},
      ]),
    );

    await client().searchByTitle('  Alien  ');

    expect(transport.requestAt(0).uri.queryParameters, <String, String>{
      'title': 'Alien',
    });
  });

  test(
    'incomplete rows are ignored and a wholly unreadable answer fails',
    () async {
      transport
        ..enqueue(
          MoviesEndpoint.upcLookup.key,
          movieSearch(<Object?>[
            <String, Object?>{'upc': '45496367619'},
            <String, Object?>{'title': 'Full Metal Jacket'},
          ]),
        )
        ..enqueue(
          MoviesEndpoint.upcLookup.key,
          movieSearch(<Object?>[
            <String, Object?>{'upc': '45496367619'},
          ]),
        );

      final matches = await client().lookupCode(id(kUpc));
      expect(matches, hasLength(1));
      expect(matches.single.codeVerified, isFalse);

      await expectLater(
        client().lookupCode(id(kUpc)),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
      );
    },
  );

  test(
    'unreadable bodies and unexpected shapes are sanitized failures',
    () async {
      transport
        ..enqueue(
          MoviesEndpoint.upcLookup.key,
          FakeMoviesCall(statusCode: 200, body: '<html>not json</html>'),
        )
        ..enqueue(
          MoviesEndpoint.upcLookup.key,
          FakeMoviesCall(statusCode: 200, json: 'plain string'),
        )
        ..enqueue(
          MoviesEndpoint.upcLookup.key,
          FakeMoviesCall(statusCode: 200, json: <String, Object?>{'count': 3}),
        );

      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          client(key: 'upcmdb-should-not-leak').lookupCode(id(kUpc)),
          throwsA(
            isA<ProviderException>()
                .having((e) => e.kind, 'kind', LookupFailureKind.malformed)
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('upcmdb-should-not-leak')),
                ),
          ),
        );
      }
    },
  );

  test(
    'status codes map to sanitized key, quota and availability guidance',
    () async {
      transport
        ..enqueue(MoviesEndpoint.upcLookup.key, movieStatus(401))
        ..enqueue(MoviesEndpoint.upcLookup.key, movieStatus(403))
        ..enqueue(
          MoviesEndpoint.upcLookup.key,
          movieStatus(429, headers: <String, String>{'retry-after': '90'}),
        )
        ..enqueue(
          MoviesEndpoint.upcLookup.key,
          movieStatus(429, headers: <String, String>{'retry-after': '999999'}),
        )
        ..enqueue(MoviesEndpoint.upcLookup.key, movieStatus(503));

      await expectLater(
        client().lookupCode(id(kUpc)),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.kind, 'kind', LookupFailureKind.http)
              .having((e) => e.message, 'message', contains('Settings')),
        ),
      );
      await expectLater(
        client().lookupCode(id(kUpc)),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.kind, 'kind', LookupFailureKind.http)
              .having((e) => e.message, 'message', contains('access')),
        ),
      );
      await expectLater(
        client().lookupCode(id(kUpc)),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.kind, 'kind', LookupFailureKind.quota)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 90),
              ),
        ),
      );
      await expectLater(
        client().lookupCode(id(kUpc)),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            maxRetryAfter,
          ),
        ),
      );
      await expectLater(
        client().lookupCode(id(kUpc)),
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

  test('only the documented endpoints and digit paths are ever built', () {
    expect(
      MoviesEndpoint.upcLookup.uri(code: kUpc).toString(),
      'https://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/lookup/'
      '045496367619',
    );
    expect(
      MoviesEndpoint.eanLookup.uri(code: kEuropeanEan).toString(),
      'https://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/lookup/ean/'
      '5051888100639',
    );
    expect(
      MoviesEndpoint.titleSearch
          .uri(query: <String, String>{'title': 'Alien', 'year': '1979'})
          .toString(),
      'https://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/search'
      '?title=Alien&year=1979',
    );
    expect(
      MoviesEndpoint.titleSearch
          .uri(query: <String, String>{'title': 'Alien', 'year': '1979'})
          .queryParameters,
      <String, String>{'title': 'Alien', 'year': '1979'},
    );

    // A non-digit, wrong-length or unsupported value is rejected before a
    // request could be built.
    for (final bad in <String?>['', '12345', '0454963676190', 'abc123456789']) {
      expect(
        () => MoviesEndpoint.upcLookup.uri(code: bad),
        throwsA(isA<ProviderException>()),
      );
    }
    expect(
      () =>
          MoviesEndpoint.titleSearch.uri(query: <String, String>{'q': 'Alien'}),
      throwsA(isA<ProviderException>()),
    );
    expect(
      () => MoviesEndpoint.upcLookup.uri(
        code: kUpc,
        query: <String, String>{'title': 'Alien'},
      ),
      throwsA(isA<ProviderException>()),
    );
  });

  test('endpoint matching refuses another host, port, path or query', () {
    final endpoint = MoviesEndpoint.upcLookup;
    expect(endpoint.matches(endpoint.uri(code: kUpc)), isTrue);
    for (final uri in <String>[
      'https://upcmdb.com/api/v1/lookup/045496367619',
      'https://us-central1-upcmdb-cbae5.cloudfunctions.net:8443/api/v1/lookup/045496367619',
      'https://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/lookup/ean/045496367619',
      'https://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/lookup/0454',
      'https://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/lookup/045496367619?title=Alien',
      'http://us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/lookup/045496367619',
      'https://key:secret@us-central1-upcmdb-cbae5.cloudfunctions.net/api/v1/lookup/045496367619',
    ]) {
      expect(endpoint.matches(Uri.parse(uri)), isFalse, reason: uri);
    }
  });
}
