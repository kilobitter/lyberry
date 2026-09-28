import 'dart:convert';

import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/providers/json.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/transport.dart';
import 'package:lyberry/services/user_agent.dart';

/// Open Library adapter: the edition record for the ISBN is tried first, then
/// work-level search rows.
///
/// The two requests are independent: if the search leg fails, an edition
/// candidate still comes back, with a warning instead of a silent loss. A work
/// `first_publish_year` is never used as the edition year, and an author is
/// never displayed as a `/authors/OL...A` identifier.
class OpenLibraryProvider implements MetadataProvider {
  OpenLibraryProvider({
    required HttpTransport transport,
    this.timeout = const Duration(seconds: 10),
    String? userAgent,
    ProviderRateLimiter? limiter,
    Clock? clock,
  }) : _transport = transport,
       _userAgent = userAgent ?? lyberryUserAgent(),
       _limiter = limiter,
       _clock = clock ?? const SystemClock();

  final HttpTransport _transport;
  final Duration timeout;
  final String _userAgent;
  final ProviderRateLimiter? _limiter;
  final Clock _clock;

  @override
  String get id => 'openlibrary';

  @override
  String get label => 'Open Library';

  @override
  Set<ProviderRole> get roles => const <ProviderRole>{ProviderRole.books};

  @override
  bool supports(MediaType? mediumHint) =>
      mediumHint == null || mediumHint == MediaType.book;

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    final identifier = query.identifier;
    final code = identifier.canonicalIsbn13;

    Map<String, Object?>? edition;
    ProviderException? editionFailure;
    try {
      edition = await _getJson(
        Uri.https('openlibrary.org', '/isbn/$code.json'),
        allowNotFound: true,
      );
    } on ProviderException catch (error) {
      editionFailure = error;
    }

    Map<String, Object?>? search;
    ProviderException? searchFailure;
    try {
      search = await _getJson(
        Uri.https('openlibrary.org', '/search.json', <String, String>{
          'isbn': code,
          'fields':
              'key,title,author_name,first_publish_year,cover_i,edition_key,publisher,isbn',
          'limit': '10',
        }),
      );
    } on ProviderException catch (error) {
      searchFailure = error;
    }

    if (edition == null && search == null) {
      throw editionFailure ??
          searchFailure ??
          const ProviderException(
            LookupFailureKind.malformed,
            'Open Library sent a response Lyberry could not read.',
          );
    }

    final candidates = <MetadataCandidate>[];
    final searchDocs = <Map<String, Object?>>[];
    ProviderException? shapeFailure;
    if (search != null) {
      try {
        final rawDocs = search['docs'];
        if (rawDocs is! List) {
          throw const ProviderException(
            LookupFailureKind.malformed,
            'Open Library sent an unexpected search response.',
          );
        }
        for (final entry in rawDocs) {
          final doc = jsonMap(entry);
          if (doc == null) {
            throw const ProviderException(
              LookupFailureKind.malformed,
              'Open Library sent a search row Lyberry could not read.',
            );
          }
          searchDocs.add(doc);
        }
      } on ProviderException catch (error) {
        shapeFailure = error;
      }
    }

    if (edition != null) {
      final editionCandidate = _editionCandidate(edition, code);
      if (editionCandidate != null) {
        candidates.add(
          _withSearchAuthor(editionCandidate, searchDocs, identifier),
        );
      }
    }

    for (final doc in searchDocs) {
      final title = jsonString(doc['title']).trim();
      if (title.isEmpty) continue;
      final key = jsonString(doc['key']);
      final isbnList = jsonList(doc['isbn']).map(jsonString);
      final exact = isbnList.any(identifier.matches);
      candidates.add(
        MetadataCandidate(
          providerId: id,
          providerLabel: label,
          externalId: key.isEmpty ? 'isbn:$code' : key,
          matchKind: exact ? MatchKind.exact : MatchKind.possible,
          title: title,
          medium: MediaType.book,
          creator: jsonFirstString(doc['author_name']),
          publisher: jsonFirstString(doc['publisher']),
          coverUrl: _coverUrl(doc['cover_i']),
          sourceUrl: key.isEmpty ? null : 'https://openlibrary.org$key',
        ),
      );
      if (candidates.length >= 6) break;
    }

    final warning = editionFailure ?? searchFailure ?? shapeFailure;
    return ProviderLookupResult(
      candidates: _dedupe(candidates),
      warning: warning == null
          ? null
          : LookupFailure(
              providerId: id,
              providerLabel: label,
              kind: warning.kind,
              message: warning.message,
              retryAfter: warning.retryAfter,
            ),
    );
  }

  /// Fills an edition candidate's author from a search row for the same ISBN,
  /// because the edition record itself only carries author *ids*.
  MetadataCandidate _withSearchAuthor(
    MetadataCandidate editionCandidate,
    List<Map<String, Object?>> searchDocs,
    NormalizedIdentifier identifier,
  ) {
    if (editionCandidate.creator.trim().isNotEmpty) return editionCandidate;
    for (final doc in searchDocs) {
      final isbnList = jsonList(doc['isbn']).map(jsonString);
      if (!isbnList.any(identifier.matches)) continue;
      final names = jsonFirstString(doc['author_name']).trim();
      if (names.isNotEmpty) {
        return MetadataCandidate(
          providerId: editionCandidate.providerId,
          providerLabel: editionCandidate.providerLabel,
          externalId: editionCandidate.externalId,
          matchKind: editionCandidate.matchKind,
          title: editionCandidate.title,
          medium: editionCandidate.medium,
          creator: names,
          year: editionCandidate.year,
          publisher: editionCandidate.publisher,
          description: editionCandidate.description,
          platform: editionCandidate.platform,
          coverUrl: editionCandidate.coverUrl,
          sourceUrl: editionCandidate.sourceUrl,
        );
      }
    }
    return editionCandidate;
  }

  MetadataCandidate? _editionCandidate(
    Map<String, Object?> edition,
    String code,
  ) {
    final title = jsonString(edition['title']).trim();
    if (title.isEmpty) return null;
    final key = jsonString(edition['key']);
    return MetadataCandidate(
      providerId: id,
      providerLabel: label,
      externalId: key.isEmpty ? 'isbn:$code' : key,
      matchKind: MatchKind.exact,
      title: title,
      medium: MediaType.book,
      creator: jsonString(edition['by_statement']).trim(),
      year: jsonYear(edition['publish_date']),
      publisher: jsonFirstString(edition['publishers']),
      coverUrl: _coverUrl(
        jsonList(edition['covers']).isEmpty
            ? null
            : jsonList(edition['covers']).first,
      ),
      sourceUrl: key.isEmpty ? null : 'https://openlibrary.org$key',
    );
  }

  String? _coverUrl(Object? coverId) {
    final id = coverId is int ? coverId : int.tryParse(jsonString(coverId));
    return id == null ? null : 'https://covers.openlibrary.org/b/id/$id-L.jpg';
  }

  Future<Map<String, Object?>?> _getJson(
    Uri uri, {
    bool allowNotFound = false,
  }) async {
    // Throttle at the request boundary: the edition and search legs are two
    // requests and each one respects the provider's spacing rule.
    await _limiter?.guard();

    final TransportResponse response;
    try {
      response = await _transport.get(
        uri,
        headers: <String, String>{
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        },
        timeout: timeout,
      );
    } on TransportException catch (error) {
      throw ProviderException(
        error.kind,
        error.message,
        retryAfter: error.retryAfter,
      );
    }

    if (response.statusCode == 404 && allowNotFound) return null;
    if (response.statusCode == 429) {
      throw ProviderException(
        LookupFailureKind.quota,
        'Open Library asked Lyberry to slow down.',
        retryAfter:
            parseRetryAfter(response.header('retry-after'), clock: _clock) ??
            const Duration(seconds: 30),
      );
    }
    if (response.statusCode >= 400) {
      throw ProviderException(
        LookupFailureKind.http,
        'Open Library answered ${response.statusCode}.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'Open Library sent a response Lyberry could not read.',
      );
    }
    final map = jsonMap(decoded);
    if (map == null) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'Open Library sent an unexpected response shape.',
      );
    }
    return map;
  }

  List<MetadataCandidate> _dedupe(List<MetadataCandidate> candidates) {
    final seen = <String>{};
    final result = <MetadataCandidate>[];
    for (final candidate in candidates) {
      if (seen.add(candidate.key)) result.add(candidate);
    }
    return result;
  }
}
