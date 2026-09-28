import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/movies/movie_catalog.dart';
import 'package:lyberry/services/movies/movies_transport.dart';

/// Scripted UPCMDB transport: records every request and answers by endpoint.
class FakeMoviesTransport implements MoviesTransport {
  final List<MoviesRequest> requests = <MoviesRequest>[];
  final Map<String, List<FakeMoviesCall>> _script =
      <String, List<FakeMoviesCall>>{};
  final Map<String, int> _cursor = <String, int>{};

  int get calls => requests.length;

  MoviesRequest requestAt(int index) => requests[index];

  List<String> get endpoints =>
      requests.map((request) => request.endpoint.key).toList(growable: false);

  List<String> get paths =>
      requests.map((request) => request.uri.path).toList(growable: false);

  List<String> get apiKeys => requests
      .map((request) => request.headers['x-api-key'] ?? '')
      .toList(growable: false);

  void enqueue(String endpointKey, FakeMoviesCall call) {
    _script.putIfAbsent(endpointKey, () => <FakeMoviesCall>[]).add(call);
  }

  @override
  Future<MoviesResponse> get(
    MoviesRequest request, {
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
    return MoviesResponse(
      statusCode: call.statusCode,
      bytes: Uint8List.fromList(utf8.encode(body)),
      headers: call.headers,
    );
  }
}

class FakeMoviesCall {
  FakeMoviesCall({
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

/// One documented flat UPCMDB record (the shape the API reference shows).
FakeMoviesCall movieRecord({
  String upc = '',
  String ean = '',
  required String title,
  Object? year,
  String? format,
  String? mediaType,
  String? specialFeatures,
  String? publisher,
  String? imdbId,
  String? plot,
  String? runtime,
  String? genre,
  String? director,
  String? actors,
  Object? imdbRating,
  String? rated,
  String? productImageUrl,
  int statusCode = 200,
}) => FakeMoviesCall(
  statusCode: statusCode,
  json: <String, Object?>{
    if (upc.isNotEmpty) 'upc': upc,
    if (ean.isNotEmpty) 'ean': ean,
    'title': title,
    'year': ?year,
    'format': ?format,
    'mediaType': ?mediaType,
    'special_features': ?specialFeatures,
    'publisher': ?publisher,
    'imdbID': ?imdbId,
    'plot': ?plot,
    'runtime': ?runtime,
    'genre': ?genre,
    'director': ?director,
    'actors': ?actors,
    'imdbRating': ?imdbRating,
    'rated': ?rated,
    'productImageUrl': ?productImageUrl,
  },
);

/// The homepage's `{status, data}` envelope around one record.
FakeMoviesCall movieWrapped(
  Object? data, {
  String status = 'success',
  int statusCode = 200,
}) => FakeMoviesCall(
  statusCode: statusCode,
  json: <String, Object?>{'status': status, 'data': data},
);

/// A title-search answer: an array of records.
FakeMoviesCall movieSearch(List<Object?> rows, {int statusCode = 200}) =>
    FakeMoviesCall(statusCode: statusCode, json: rows);

FakeMoviesCall movieNotFound() => FakeMoviesCall(
  statusCode: 404,
  json: <String, Object?>{'error': 'UPC not found in database.'},
);

FakeMoviesCall movieStatus(
  int statusCode, {
  Map<String, String> headers = const <String, String>{},
  Object? json,
}) => FakeMoviesCall(statusCode: statusCode, headers: headers, json: json);

/// Fake catalog for widget tests: no network, scripted outcome.
class FakeMovieCatalog implements MovieCatalog {
  FakeMovieCatalog({
    this.configured = true,
    List<MetadataCandidate>? candidates,
    this.failure,
    this.configuredError,
    this.throwOnSearch,
    this.delay = Duration.zero,
  }) : candidates = candidates ?? const <MetadataCandidate>[];

  bool configured;
  List<MetadataCandidate> candidates;
  LookupFailure? failure;

  /// When set, reading the credential state fails instead of answering.
  ProviderException? configuredError;

  /// When set, a search throws this instead of returning an outcome, so a
  /// stale-error path can be exercised.
  Object? throwOnSearch;
  Duration delay;

  final List<String> queries = <String>[];
  final List<int?> years = <int?>[];
  int invalidations = 0;

  @override
  Future<bool> get isConfigured async {
    final error = configuredError;
    if (error != null) throw error;
    return configured;
  }

  @override
  Future<MovieSearchOutcome> searchByTitle(String title, {int? year}) async {
    queries.add(title);
    years.add(year);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final thrown = throwOnSearch;
    if (thrown != null) throw thrown;
    return MovieSearchOutcome(candidates: candidates, failure: failure);
  }

  @override
  void invalidateCredentials() => invalidations++;
}

/// Builds a movie candidate the way the real service does.
MetadataCandidate movieCandidate({
  required String title,
  required String identity,
  String format = 'DVD',
  String edition = '',
  int? year,
  String creator = '',
  String publisher = '',
  String description = '',
  String? coverUrl,
  String? sourceUrl,
  MatchKind matchKind = MatchKind.possible,
  MediaType? medium = MediaType.dvd,
}) => MetadataCandidate(
  providerId: 'upcmdb',
  providerLabel: 'UPCMDB',
  externalId: 'upcmdb:$identity|${format.toLowerCase()}',
  matchKind: matchKind,
  title: title,
  medium: medium,
  creator: creator,
  year: year,
  publisher: publisher,
  description: description,
  format: format,
  edition: edition,
  coverUrl: coverUrl,
  sourceUrl: sourceUrl ?? 'https://upcmdb.com/',
);
