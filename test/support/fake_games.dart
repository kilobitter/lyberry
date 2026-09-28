import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/games/game_catalog.dart';
import 'package:lyberry/services/games/games_transport.dart';

/// Scripted games transport: records every request and answers by endpoint.
class FakeGamesTransport implements GamesTransport {
  final List<GamesRequest> requests = <GamesRequest>[];
  final Map<String, List<FakeGamesCall>> _script =
      <String, List<FakeGamesCall>>{};
  final Map<String, int> _cursor = <String, int>{};

  int get calls => requests.length;

  GamesRequest requestAt(int index) => requests[index];

  List<String> get endpoints =>
      requests.map((request) => request.endpoint.key).toList(growable: false);

  void enqueue(String endpointKey, FakeGamesCall call) {
    _script.putIfAbsent(endpointKey, () => <FakeGamesCall>[]).add(call);
  }

  @override
  Future<GamesResponse> send(
    GamesRequest request, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    requests.add(request);
    final queue = _script[request.endpoint.key];
    if (queue == null || queue.isEmpty) {
      throw ProviderException(
        LookupFailureKind.network,
        'No scripted answer for ${request.endpoint.key}.',
      );
    }
    // Consume the next scripted answer; once the script is exhausted the last
    // one repeats, so tests can enqueue up front or just in time.
    final cursor = _cursor[request.endpoint.key] ?? 0;
    final call = cursor < queue.length ? queue[cursor] : queue.last;
    _cursor[request.endpoint.key] = cursor + 1;
    if (call.delay > Duration.zero) {
      await Future<void>.delayed(call.delay);
    }
    if (call.error != null) throw call.error!;
    final body = call.body ?? jsonEncode(call.json);
    return GamesResponse(
      statusCode: call.statusCode,
      bytes: Uint8List.fromList(utf8.encode(body)),
      headers: call.headers,
    );
  }
}

class FakeGamesCall {
  FakeGamesCall({
    required this.statusCode,
    this.json,
    this.body,
    this.headers = const <String, String>{},
    this.delay = Duration.zero,
    this.error,
  });

  final int statusCode;
  final Object? json;
  final String? body;
  final Map<String, String> headers;
  final Duration delay;
  final ProviderException? error;
}

/// ScanDex-shaped answer.
FakeGamesCall scanDexMatch({
  required int gameId,
  required String name,
  int? platformId,
  String? platformName,
  String source = 'import',
}) => FakeGamesCall(
  statusCode: 200,
  json: <String, Object?>{
    'id': 'record-$gameId',
    'source': source,
    'igdb_metadata': <String, Object?>{
      'id': gameId,
      'name': name,
      'platform': <String, Object?>{'id': ?platformId, 'name': ?platformName},
    },
  },
);

FakeGamesCall scanDexUnmatched() => FakeGamesCall(
  statusCode: 200,
  json: <String, Object?>{'status': 'unmatched', 'igdb_metadata': null},
);

/// Twitch token answer.
FakeGamesCall twitchToken({String token = 'app-token', int expiresIn = 3600}) =>
    FakeGamesCall(
      statusCode: 200,
      json: <String, Object?>{
        'access_token': token,
        'expires_in': expiresIn,
        'token_type': 'bearer',
      },
    );

/// IGDB games answer with one game.
FakeGamesCall igdbGame({
  required int id,
  required String name,
  String? url,
  String? summary,
  String? imageId,
  List<int> platformIds = const <int>[],
  Map<String, String> platformNames = const <String, String>{},
  Map<int, int> releaseYears = const <int, int>{},
  String? developer,
  String? publisher,
}) => FakeGamesCall(
  statusCode: 200,
  json: <Object?>[
    <String, Object?>{
      'id': id,
      'name': name,
      'url': ?url,
      'summary': ?summary,
      if (imageId != null) 'cover': <String, Object?>{'image_id': imageId},
      'platforms': <Object?>[
        for (final platformId in platformIds)
          <String, Object?>{
            'id': platformId,
            'name': platformNames['$platformId'] ?? 'Platform $platformId',
          },
      ],
      'involved_companies': <Object?>[
        if (developer != null)
          <String, Object?>{
            'company': <String, Object?>{'name': developer},
            'developer': true,
            'publisher': false,
          },
        if (publisher != null)
          <String, Object?>{
            'company': <String, Object?>{'name': publisher},
            'developer': false,
            'publisher': true,
          },
      ],
      'release_dates': <Object?>[
        for (final entry in releaseYears.entries)
          <String, Object?>{'platform': entry.key, 'y': entry.value},
      ],
    },
  ],
);

FakeGamesCall igdbEmpty() => FakeGamesCall(statusCode: 200, json: <Object?>[]);

/// Fake catalog for widget tests: no network, scripted outcome.
class FakeGameCatalog implements GameCatalog {
  FakeGameCatalog({
    this.configured = true,
    List<MetadataCandidate>? candidates,
    this.failure,
    this.configuredError,
    this.delay = Duration.zero,
  }) : candidates = candidates ?? const <MetadataCandidate>[];

  bool configured;
  List<MetadataCandidate> candidates;
  LookupFailure? failure;

  /// When set, reading the credential state fails instead of answering.
  ProviderException? configuredError;
  Duration delay;

  final List<String> queries = <String>[];
  int invalidations = 0;

  @override
  Future<bool> get isConfigured async {
    final error = configuredError;
    if (error != null) throw error;
    return configured;
  }

  @override
  Future<GameSearchOutcome> searchByTitle(String title) async {
    queries.add(title);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    return GameSearchOutcome(candidates: candidates, failure: failure);
  }

  @override
  void invalidateCredentials() => invalidations++;
}

/// Builds a game candidate the way the real service does.
MetadataCandidate gameCandidate({
  required String title,
  required int gameId,
  int? platformId,
  String platformName = '',
  int? year,
  MatchKind matchKind = MatchKind.possible,
}) => MetadataCandidate(
  providerId: 'igdb',
  providerLabel: 'IGDB',
  externalId: 'igdb:$gameId:${platformId ?? 'any'}',
  matchKind: matchKind,
  title: title,
  medium: MediaType.game,
  year: year,
  platform: platformName,
  sourceUrl: 'https://www.igdb.com/games/$gameId',
);
