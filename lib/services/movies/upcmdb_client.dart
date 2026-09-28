import 'package:lyberry/domain/barcode.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/movies/movies_transport.dart';
import 'package:lyberry/services/providers/json.dart';

/// One UPCMDB record, parsed from either documented response shape.
///
/// Nullable fields stay empty/null when the service omitted them; nothing here
/// invents a value. `format`, `special_features` and `mediaType` feed the
/// DVD/Blu-ray mapping, and `productImageUrl` is only a public HTTPS cover URL
/// that the existing downloader validates again.
class MovieRecord {
  const MovieRecord({
    required this.title,
    this.upc = '',
    this.ean = '',
    this.year,
    this.format = '',
    this.mediaType = '',
    this.specialFeatures = '',
    this.publisher = '',
    this.imdbId = '',
    this.plot = '',
    this.runtime = '',
    this.genre = '',
    this.director = '',
    this.actors = '',
    this.imdbRating,
    this.rated = '',
    this.productImageUrl = '',
  });

  final String title;

  /// The code the record carries, when it carries one.
  final String upc;
  final String ean;

  final int? year;
  final String format;
  final String mediaType;
  final String specialFeatures;
  final String publisher;
  final String imdbId;
  final String plot;
  final String runtime;
  final String genre;
  final String director;
  final String actors;
  final double? imdbRating;
  final String rated;
  final String productImageUrl;

  bool get hasCodeEvidence => upc.trim().isNotEmpty || ean.trim().isNotEmpty;

  /// True when one of the record's own codes is the requested code or a
  /// documented equivalent (UPC-12 <-> leading-zero EAN-13, short numeric UPC
  /// left-padded to 12 with a valid checksum). Never guesses from a title.
  bool matchesCode(NormalizedIdentifier identifier) {
    for (final candidate in <String>[upc, ean]) {
      if (candidate.trim().isEmpty) continue;
      if (codesAreEquivalent(candidate, identifier.value)) return true;
      for (final equivalent in identifier.equivalents) {
        if (codesAreEquivalent(candidate, equivalent)) return true;
      }
    }
    return false;
  }

  /// Returns `null` for an incomplete or non-object row, which the caller
  /// ignores rather than turning into a candidate.
  static MovieRecord? tryParse(Object? value) {
    final map = jsonMap(value);
    if (map == null) return null;
    final title = jsonString(map['title']).trim();
    if (title.isEmpty) return null;
    return MovieRecord(
      title: title,
      upc: jsonString(map['upc']).trim(),
      ean: jsonString(map['ean']).trim(),
      year: jsonYear(map['year']),
      format: jsonString(map['format']).trim(),
      mediaType: jsonString(map['mediaType']).trim(),
      specialFeatures: jsonString(map['special_features']).trim(),
      publisher: jsonString(map['publisher']).trim(),
      imdbId: jsonString(map['imdbID']).trim(),
      plot: jsonString(map['plot']).trim(),
      runtime: jsonString(map['runtime']).trim(),
      genre: jsonString(map['genre']).trim(),
      director: jsonString(map['director']).trim(),
      actors: jsonString(map['actors']).trim(),
      imdbRating: _rating(map['imdbRating']),
      rated: jsonString(map['rated']).trim(),
      productImageUrl: jsonString(map['productImageUrl']).trim(),
    );
  }
}

/// One acceptable record from a barcode lookup.
class MovieCodeMatch {
  const MovieCodeMatch(this.record, {required this.codeVerified});

  final MovieRecord record;

  /// True when the record carried the requested code (or its documented
  /// equivalent). When false the record is still usable, but only as a
  /// possible match.
  final bool codeVerified;
}

/// UPCMDB barcode identification and explicit title search.
///
/// The API key travels as the raw `x-api-key` header (no Bearer prefix and
/// never a URL parameter). The documented Cloud Functions base is used, not the
/// homepage's marketing example, and every URL is built from a fixed endpoint
/// template plus a validated code or encoded query.
class UpcMdbClient {
  UpcMdbClient({
    required MoviesTransport transport,
    required String apiKey,
    this.timeout = MoviesEndpointLimits.requestTimeout,
  }) : _transport = transport,
       _apiKey = apiKey;

  static const int maxBytes = 1024 * 1024;
  static const int maxTitleLength = 200;

  final MoviesTransport _transport;
  final String _apiKey;
  final Duration timeout;

  /// Identifies one barcode.
  ///
  /// UPC-A, or an EAN-13 that is a leading-zero UPC-A, uses the single UPC-12
  /// call; any other EAN-13 uses the EAN route unchanged. ISBN and EAN-8 codes
  /// are not movie codes and never produce a request.
  Future<List<MovieCodeMatch>> lookupCode(
    NormalizedIdentifier identifier,
  ) async {
    final MoviesEndpoint endpoint;
    final String code;
    switch (identifier.kind) {
      case IdentifierKind.upcA:
        endpoint = MoviesEndpoint.upcLookup;
        code = identifier.value;
      case IdentifierKind.ean13:
        if (identifier.value.startsWith('0')) {
          endpoint = MoviesEndpoint.upcLookup;
          code = identifier.value.substring(1);
        } else {
          // A European EAN-13 must never be truncated to a UPC.
          endpoint = MoviesEndpoint.eanLookup;
          code = identifier.value;
        }
      case IdentifierKind.isbn10:
      case IdentifierKind.isbn13:
      case IdentifierKind.ean8:
        return const <MovieCodeMatch>[];
    }

    final response = await _send(endpoint.uri(code: code), endpoint);
    if (response.statusCode == 404) return const <MovieCodeMatch>[];
    if (response.statusCode != 200) {
      throw upcMdbStatusException(
        response.statusCode,
        retryAfter: response.header('retry-after'),
      );
    }
    final rows = _rowsFrom(decodeMoviesJson(response.body));
    return _codeMatches(rows, identifier);
  }

  /// Explicit title search. [title] is trimmed and bounded by the caller and
  /// the optional [year] must be a four-digit year.
  Future<List<MovieRecord>> searchByTitle(String title, {int? year}) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'A movie title search needs a title.',
      );
    }
    final query = <String, String>{
      'title': trimmed.length > maxTitleLength
          ? trimmed.substring(0, maxTitleLength)
          : trimmed,
      if (year != null) 'year': '$year',
    };
    final response = await _send(
      MoviesEndpoint.titleSearch.uri(query: query),
      MoviesEndpoint.titleSearch,
    );
    if (response.statusCode == 404) return const <MovieRecord>[];
    if (response.statusCode != 200) {
      throw upcMdbStatusException(
        response.statusCode,
        retryAfter: response.header('retry-after'),
      );
    }
    final rows = _rowsFrom(decodeMoviesJson(response.body));
    return _searchRecords(rows);
  }

  Future<MoviesResponse> _send(Uri uri, MoviesEndpoint endpoint) {
    return _transport.get(
      MoviesRequest(
        endpoint: endpoint,
        uri: uri,
        headers: <String, String>{'x-api-key': _apiKey},
      ),
      timeout: timeout,
      maxBytes: maxBytes,
    );
  }

  final List<Object?> _noRows = const <Object?>[];

  /// Unwraps the documented `{status, data}` envelope and rejects anything that
  /// is neither a record, a list of records, nor that envelope.
  List<Object?> _rowsFrom(Object? decoded) {
    var payload = decoded;
    final map = jsonMap(payload);
    if (map != null && map.containsKey('data')) {
      final status = jsonString(map['status']).trim().toLowerCase();
      if (status.isNotEmpty &&
          status != 'success' &&
          status != 'ok' &&
          status != 'succeeded') {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'UPCMDB answered with an error envelope.',
        );
      }
      payload = map['data'];
    }
    if (payload is List) return jsonList(payload);
    if (jsonMap(payload) != null) return <Object?>[payload];
    if (payload == null) return _noRows;
    throw const ProviderException(
      LookupFailureKind.malformed,
      'UPCMDB sent an unexpected response shape.',
    );
  }

  List<MovieCodeMatch> _codeMatches(
    List<Object?> rows,
    NormalizedIdentifier identifier,
  ) {
    if (rows.isEmpty) return const <MovieCodeMatch>[];
    final matches = <MovieCodeMatch>[];
    var parsed = 0;
    var mismatched = false;
    for (final row in rows) {
      final record = MovieRecord.tryParse(row);
      if (record == null) continue;
      parsed++;
      if (!record.hasCodeEvidence) {
        // Title-only evidence is usable, but it can never be an exact match.
        matches.add(MovieCodeMatch(record, codeVerified: false));
        continue;
      }
      if (record.matchesCode(identifier)) {
        matches.add(MovieCodeMatch(record, codeVerified: true));
      } else {
        mismatched = true;
      }
    }
    if (matches.isNotEmpty) return matches;
    if (mismatched) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'UPCMDB answered with a record for a different code.',
      );
    }
    if (parsed == 0) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'UPCMDB sent a record Lyberry could not read.',
      );
    }
    return const <MovieCodeMatch>[];
  }

  List<MovieRecord> _searchRecords(List<Object?> rows) {
    if (rows.isEmpty) return const <MovieRecord>[];
    final records = <MovieRecord>[];
    for (final row in rows) {
      final record = MovieRecord.tryParse(row);
      if (record != null) records.add(record);
    }
    if (records.isEmpty) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'UPCMDB sent search results Lyberry could not read.',
      );
    }
    return records;
  }
}

/// True when two numeric codes are the same identifier, allowing the documented
/// UPC-12 / leading-zero EAN-13 pair and a short numeric UPC that left-pads to
/// the same 12 digits with a valid checksum.
///
/// Both values must be digits only after trimming: `UPC 0454…`, `0454…-x` and
/// any other prefixed, suffixed or non-numeric text is never a code match, so a
/// stray label can never be presented as an exact identification.
bool codesAreEquivalent(String a, String b) {
  final left = _strictDigits(a);
  final right = _strictDigits(b);
  if (left == null || right == null) return false;
  // Both sides are validated even when they are textually identical: an
  // invalid-checksum, overlong or too-short code is never a match, not even
  // with itself.
  final canonicalLeft = _canonicalCode(left);
  final canonicalRight = _canonicalCode(right);
  if (canonicalLeft == null || canonicalRight == null) return false;
  return canonicalLeft == canonicalRight;
}

/// Digits only, or `null` when the value carries anything else.
String? _strictDigits(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  for (final unit in trimmed.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return null;
  }
  return trimmed;
}

/// The validated form of a numeric code, or `null` when it is not a usable
/// UPC/EAN: a checksum-valid UPC-12, a checksum-valid EAN-13 (with a
/// leading-zero EAN-13 reduced to the UPC-12 it stands for), or a short numeric
/// UPC of 8-11 digits left-padded to 12 with a valid checksum.
String? _canonicalCode(String digits) {
  if (digits.length == 13) {
    if (!Barcode.isValid(digits)) return null;
    if (digits.startsWith('0')) {
      final upc = digits.substring(1);
      if (Barcode.isValid(upc)) return upc;
    }
    return digits;
  }
  if (digits.length < 8 || digits.length > 12) return null;
  final padded = digits.padLeft(12, '0');
  if (!Barcode.isValid(padded)) return null;
  return padded;
}

double? _rating(Object? value) {
  if (value is num) {
    final parsed = value.toDouble();
    return parsed.isFinite ? parsed : null;
  }
  final text = jsonString(value).trim();
  if (text.isEmpty) return null;
  final parsed = double.tryParse(text);
  return parsed != null && parsed.isFinite ? parsed : null;
}
