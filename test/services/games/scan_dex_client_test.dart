import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/games/scan_dex_client.dart';

import '../../support/fake_games.dart';

void main() {
  late FakeGamesTransport transport;

  setUp(() => transport = FakeGamesTransport());

  ScanDexClient client({String token = 'scandex-synthetic-token'}) =>
      ScanDexClient(transport: transport, token: token);

  FakeGamesCall lookup({required Object? json, int statusCode = 200}) =>
      FakeGamesCall(statusCode: statusCode, json: json);

  void enqueue(FakeGamesCall call) =>
      transport.enqueue(GamesEndpoint.scanDexLookup.key, call);

  test('resolves a match and sends the raw Authorization token', () async {
    enqueue(
      scanDexMatch(
        gameId: 7346,
        name: 'Wii Sports Resort',
        platformId: 5,
        platformName: 'Wii',
      ),
    );

    // The UPC keeps its leading zero.
    final match = await client().lookup('0045496367619');

    expect(match, isNotNull);
    expect(match!.igdbId, 7346);
    expect(match.title, 'Wii Sports Resort');
    expect(match.platformId, 5);
    expect(match.platformName, 'Wii');
    expect(match.isCommunity, isFalse);

    final request = transport.requestAt(0);
    expect(request.endpoint, GamesEndpoint.scanDexLookup);
    expect(request.uri.queryParameters['value'], '0045496367619');
    expect(request.headers['Authorization'], 'scandex-synthetic-token');
    expect(request.headers.values.join(), isNot(contains('Bearer')));
  });

  test('404, unmatched and missing metadata are no match', () async {
    enqueue(FakeGamesCall(statusCode: 404, body: 'not found'));
    expect(await client().lookup('5051888100639'), isNull);

    final second = FakeGamesTransport()
      ..enqueue(GamesEndpoint.scanDexLookup.key, scanDexUnmatched());
    expect(
      await ScanDexClient(transport: second, token: 't').lookup('1'),
      isNull,
    );

    final third = FakeGamesTransport()
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        lookup(json: <String, Object?>{'igdb_metadata': null}),
      );
    expect(
      await ScanDexClient(transport: third, token: 't').lookup('1'),
      isNull,
    );
  });

  test('community entries are flagged and imported ones are not', () async {
    enqueue(scanDexMatch(gameId: 1, name: 'Community entry', source: 'user'));
    final community = await client().lookup('1');
    expect(community!.isCommunity, isTrue);
    expect(community.isImported, isFalse);

    final second = FakeGamesTransport()
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        scanDexMatch(gameId: 2, name: 'Imported entry', source: 'imported'),
      );
    final imported = await ScanDexClient(
      transport: second,
      token: 't',
    ).lookup('2');
    expect(imported!.isImported, isTrue);
  });

  test('the documented import literal and v2 example resolve', () async {
    // Shape from the documented v2 example: source "import".
    enqueue(
      lookup(
        json: <String, Object?>{
          'id': '507f1f77bcf86cd799439011',
          'source': 'import',
          'igdb_metadata': <String, Object?>{
            'id': 1029,
            'name': 'The Legend of Zelda',
            'platform': <String, Object?>{'id': 19, 'name': 'Super Nintendo'},
          },
        },
      ),
    );
    final match = await client().lookup('0045496367619');
    expect(match!.isImported, isTrue);
    expect(match.isCommunity, isFalse);
    expect(match.igdbId, 1029);
    expect(match.platformName, 'Super Nintendo');
  });

  test('rejects malformed ids, names and shapes', () async {
    for (final metadata in <Object?>[
      <String, Object?>{'id': 0, 'name': 'Zero id'},
      <String, Object?>{'id': -4, 'name': 'Negative id'},
      <String, Object?>{'name': 'No id'},
      <String, Object?>{'id': 7, 'name': '   '},
      <String, Object?>{'id': 7.5, 'name': 'Fractional id'},
    ]) {
      final scoped = FakeGamesTransport()
        ..enqueue(
          GamesEndpoint.scanDexLookup.key,
          lookup(json: <String, Object?>{'igdb_metadata': metadata}),
        );
      await expectLater(
        ScanDexClient(transport: scoped, token: 't').lookup('1'),
        throwsA(
          isA<ProviderException>().having(
            (error) => error.kind,
            'kind',
            LookupFailureKind.malformed,
          ),
        ),
      );
    }

    final notJson = FakeGamesTransport()
      ..enqueue(
        GamesEndpoint.scanDexLookup.key,
        FakeGamesCall(statusCode: 200, body: '<html>nope</html>'),
      );
    await expectLater(
      ScanDexClient(transport: notJson, token: 't').lookup('1'),
      throwsA(isA<ProviderException>()),
    );
  });

  test('maps auth and quota statuses to sanitized failures', () async {
    for (final (status, kind) in <(int, LookupFailureKind)>[
      (401, LookupFailureKind.http),
      (429, LookupFailureKind.quota),
      (503, LookupFailureKind.unavailable),
    ]) {
      final scoped = FakeGamesTransport()
        ..enqueue(
          GamesEndpoint.scanDexLookup.key,
          FakeGamesCall(
            statusCode: status,
            body: jsonEncode(<String, Object?>{
              'message': 'token scandex-synthetic-token leaked?',
            }),
          ),
        );
      await expectLater(
        ScanDexClient(
          transport: scoped,
          token: 'scandex-synthetic-token',
        ).lookup('1'),
        throwsA(
          isA<ProviderException>()
              .having((error) => error.kind, 'kind', kind)
              .having(
                (error) => error.message,
                'message',
                isNot(contains('scandex-synthetic-token')),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('leaked')),
              ),
        ),
      );
    }
  });
}
