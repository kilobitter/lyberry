import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/cover_downloader.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/movies/movie_catalog.dart';
import 'package:lyberry/services/movies/movies_request_gate.dart';
import 'package:lyberry/services/movies/movies_transport.dart';
import 'package:lyberry/services/movies/upcmdb_client.dart';

/// UPCMDB barcode identification and movie metadata, as one provider.
///
/// Barcode lookups go through [MetadataProvider]; title searches go through
/// [MovieCatalog]. Both share one request gate (spacing, concurrency and 429
/// cooldown) and one credential generation, so a key change in Settings can
/// neither start a new request with a removed key nor let an old answer
/// repopulate the cache.
class MoviesLookupService implements MetadataProvider, MovieCatalog {
  MoviesLookupService({
    required ApiKeyStore keys,
    required MoviesTransport transport,
    required MoviesRequestGate gate,
    LookupCache? cache,
  }) : _keys = keys,
       _transport = transport,
       _gate = gate,
       _cache = cache;

  static const String providerId = 'upcmdb';
  static const String providerLabel = 'UPCMDB';

  /// The API returns an array for a title search; Lyberry keeps only this many
  /// valid unique candidates.
  static const int maxMovieCandidates = 20;

  /// Fallback cooldown when UPCMDB answers 429 without a usable `Retry-After`.
  static const Duration quotaCooldownFallback = Duration(seconds: 60);

  final ApiKeyStore _keys;
  final MoviesTransport _transport;
  final MoviesRequestGate _gate;
  final LookupCache? _cache;

  int _generation = 0;

  /// Rate-limit status so Settings can show a movies cooldown.
  Duration get cooldownRemaining => _gate.cooldownRemaining;

  @override
  String get id => providerId;

  @override
  String get label => providerLabel;

  @override
  Set<ProviderRole> get roles => const <ProviderRole>{ProviderRole.movies};

  /// Movies answer for an explicit DVD/Blu-ray hint and for unknown non-ISBN
  /// codes; book, music and game hints never reach this provider.
  @override
  bool supports(MediaType? mediumHint) =>
      mediumHint == null ||
      mediumHint == MediaType.dvd ||
      mediumHint == MediaType.bluray;

  @override
  Future<bool> get isConfigured async {
    final key = await _readKey();
    return key != null && key.trim().isNotEmpty;
  }

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    final generation = _generation;
    final key = await _readKey();
    // The key read awaited: a credential change during it must abort before any
    // request is started.
    _assertCurrent(generation);
    if (key == null || key.trim().isEmpty) {
      // No request without credentials, and a clean empty answer for every
      // hint, so the existing providers and the general fallback still answer a
      // barcode normally with no spurious UPCMDB failure. Setup guidance for a
      // missing key lives in the explicit title search screen, the only place
      // the user asked for UPCMDB.
      return ProviderLookupResult();
    }

    final client = UpcMdbClient(transport: _transport, apiKey: key);
    final matches = await _guarded(() {
      // The gate may have made this call wait for a slot or for the spacing
      // rule: a key removed while it waited must not be used for a request.
      _assertCurrent(generation);
      return client.lookupCode(query.identifier);
    });
    _assertCurrent(generation);
    if (matches.isEmpty) return ProviderLookupResult();

    final candidates = _bound(<MetadataCandidate>[
      for (final match in matches)
        _candidateFromMatch(match, hint: query.mediumHint),
    ]);
    if (candidates.isEmpty) return ProviderLookupResult();
    return ProviderLookupResult(candidates: candidates);
  }

  @override
  Future<MovieSearchOutcome> searchByTitle(String title, {int? year}) async {
    final generation = _generation;
    final String? key;
    try {
      key = await _readKey();
    } on ProviderException catch (error) {
      return MovieSearchOutcome(
        failure: _failure(
          LookupFailureKind.unavailable,
          'The UPCMDB API key could not be read on this device. '
          '${error.message}',
        ),
      );
    }
    if (key == null || key.trim().isEmpty) {
      return MovieSearchOutcome(
        failure: _failure(
          LookupFailureKind.unavailable,
          'Add your UPCMDB API key in Settings to search movies by title.',
        ),
      );
    }
    // The key read awaited: never send with a key that was replaced meanwhile.
    if (generation != _generation) {
      return MovieSearchOutcome(
        failure: _failure(
          LookupFailureKind.unavailable,
          'The UPCMDB key changed during the search.',
        ),
      );
    }

    final client = UpcMdbClient(transport: _transport, apiKey: key);
    try {
      final records = await _guarded(() {
        // Same rule as the barcode path: re-check after the gate admits this
        // request, immediately before it could be sent.
        _assertCurrent(generation);
        return client.searchByTitle(title, year: year);
      });
      _assertCurrent(generation);
      final candidates = _bound(<MetadataCandidate>[
        for (final record in records)
          _candidateFromRecord(record, codeVerified: false, hint: null),
      ]);
      return MovieSearchOutcome(candidates: candidates);
    } on ProviderException catch (error) {
      return MovieSearchOutcome(failure: _failure(error.kind, error.message));
    }
  }

  @override
  void invalidateCredentials() {
    _generation++;
    _cache?.clear();
  }

  /// Runs one request behind the shared gate and applies a 429 cooldown to the
  /// same gate, so the barcode and title paths cannot spend double quota.
  Future<T> _guarded<T>(Future<T> Function() action) async {
    try {
      return await _gate.run(action);
    } on ProviderException catch (error) {
      if (error.kind == LookupFailureKind.quota) {
        _gate.penalize(error.retryAfter ?? quotaCooldownFallback);
      }
      rethrow;
    }
  }

  Future<String?> _readKey() async {
    try {
      return await _keys.read(MovieKeyProvider.upcmdb);
    } on WebLookupException catch (error) {
      // Sanitized storage failure, never a "no key" answer.
      throw ProviderException(
        LookupFailureKind.unavailable,
        'The UPCMDB API key could not be read on this device. ${error.message}',
      );
    } on Object {
      throw const ProviderException(
        LookupFailureKind.unavailable,
        'The UPCMDB API key could not be read on this device.',
      );
    }
  }

  /// Throws when the key changed while an operation was in flight, so an old
  /// request can neither be accepted nor cached.
  void _assertCurrent(int generation) {
    if (generation != _generation) {
      // `unavailable`, not `cooldown`: a credential change must not penalize the
      // shared UPCMDB limiter as if it were a provider quota failure.
      throw const ProviderException(
        LookupFailureKind.unavailable,
        'The UPCMDB key changed during the lookup.',
      );
    }
  }

  MetadataCandidate _candidateFromMatch(
    MovieCodeMatch match, {
    required MediaType? hint,
  }) => _candidateFromRecord(
    match.record,
    codeVerified: match.codeVerified,
    hint: hint,
  );

  MetadataCandidate _candidateFromRecord(
    MovieRecord record, {
    required bool codeVerified,
    required MediaType? hint,
  }) {
    final format = _formatLabel(record);
    final edition = _editionLabel(record, format);
    final description = _description(record, format);
    return MetadataCandidate(
      providerId: providerId,
      providerLabel: providerLabel,
      // Different editions of the same film must never collapse into one
      // candidate: the supplier code and the format are part of the identity,
      // with a deterministic title/year fallback.
      externalId:
          'upcmdb:${_identity(record, edition)}|'
          '${format.isEmpty ? 'unknown' : format.toLowerCase()}',
      matchKind: codeVerified ? MatchKind.exact : MatchKind.possible,
      title: record.title,
      medium: _mediumFor(record, hint),
      creator: record.director,
      year: record.year,
      publisher: record.publisher,
      description: description,
      format: format,
      edition: edition,
      coverUrl: _coverUrl(record),
      sourceUrl: _sourceUrl(record),
    );
  }

  /// Supplier code first, then a validated IMDb id, then a deterministic
  /// title/year fallback. Never invents an id. Supplied edition attributes are
  /// appended so two releases of one film cannot collapse into one candidate.
  String _identity(MovieRecord record, String edition) {
    final code = record.upc.isNotEmpty
        ? record.upc
        : (record.ean.isNotEmpty ? record.ean : '');
    final String base;
    if (code.isNotEmpty) {
      base = 'code:$code';
    } else {
      final imdbId = _imdbId(record);
      base = imdbId != null
          ? 'imdb:$imdbId'
          : 'title:${_collapse(record.title).toLowerCase()}:'
                '${record.year ?? 'unknown'}';
    }
    final attributes = <String>[
      _attribute(edition),
      _attribute(record.publisher),
    ].where((value) => value.isNotEmpty).toList(growable: false);
    if (attributes.isEmpty) return base;
    return '$base|edition:${attributes.join('/')}';
  }

  /// Extra release detail, only when it says something the format label does
  /// not already say.
  String _editionLabel(MovieRecord record, String format) {
    final special = _collapse(record.specialFeatures);
    if (special.isEmpty) return '';
    return special == format ? '' : special;
  }

  /// The validated IMDb `tt` id, or `null` when the field is absent or
  /// malformed.
  String? _imdbId(MovieRecord record) {
    final value = record.imdbId.trim();
    if (value.isEmpty) return null;
    return _imdbPattern.hasMatch(value) ? value : null;
  }

  String? _sourceUrl(MovieRecord record) {
    final imdbId = _imdbId(record);
    if (imdbId != null) return 'https://www.imdb.com/title/$imdbId/';
    // A public page, never a credential-bearing or API URL.
    return 'https://upcmdb.com/';
  }

  /// Keeps a cover URL only when the existing conservative downloader policy
  /// would accept it: HTTPS, port 443, no userinfo, no literal/private host and
  /// an allowlisted cover host. The global cover allowlist is not broadened for
  /// UPCMDB, and a URL the downloader would refuse is never kept as candidate
  /// metadata.
  String? _coverUrl(MovieRecord record) {
    final value = record.productImageUrl.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (!CoverDownloader.isAllowedUri(uri)) return null;
    return uri.toString();
  }

  /// DVD maps to DVD; Blu-ray/BD/4K/UHD maps to Blu-ray while the edition text
  /// stays in [MetadataCandidate.format] and in the description. An unknown
  /// format keeps the supplied hint, and nothing is invented.
  MediaType? _mediumFor(MovieRecord record, MediaType? hint) {
    final raw = '${record.format} ${record.mediaType} ${record.specialFeatures}'
        .toLowerCase();
    if (_blurayPattern.hasMatch(raw)) return MediaType.bluray;
    if (_dvdPattern.hasMatch(raw)) return MediaType.dvd;
    if (hint == MediaType.dvd || hint == MediaType.bluray) return hint;
    return null;
  }

  String _formatLabel(MovieRecord record) {
    final format = _collapse(record.format);
    if (format.isNotEmpty) return format;
    return _collapse(record.specialFeatures);
  }

  /// Plot plus clearly labelled optional details. Never touches the user's own
  /// rating, review or notes, and an external rating is labelled as such.
  String _description(MovieRecord record, String format) {
    final lines = <String>[];
    final plot = _collapse(record.plot);
    if (plot.isNotEmpty) lines.add(plot);
    final details = <String>[
      if (format.isNotEmpty) 'Format: $format',
      if (_collapse(record.specialFeatures).isNotEmpty &&
          _collapse(record.specialFeatures) != format)
        'Edition: ${_collapse(record.specialFeatures)}',
      if (_collapse(record.runtime).isNotEmpty)
        'Runtime: ${_collapse(record.runtime)}',
      if (_collapse(record.genre).isNotEmpty)
        'Genre: ${_collapse(record.genre)}',
      if (_collapse(record.actors).isNotEmpty)
        'Cast: ${_collapse(record.actors)}',
      if (_collapse(record.rated).isNotEmpty)
        'Rated: ${_collapse(record.rated)}',
      if (record.imdbRating != null)
        'IMDb rating: ${_trimRating(record.imdbRating!)}/10 (external)',
    ];
    if (details.isNotEmpty) lines.add(details.join('\n'));
    return lines.join('\n\n');
  }

  List<MetadataCandidate> _bound(List<MetadataCandidate> candidates) {
    final out = <MetadataCandidate>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      if (out.length >= maxMovieCandidates) break;
      if (seen.add(candidate.key)) out.add(candidate);
    }
    return out;
  }

  LookupFailure _failure(LookupFailureKind kind, String message) =>
      LookupFailure(
        providerId: providerId,
        providerLabel: providerLabel,
        kind: kind,
        message: message,
      );

  static final RegExp _imdbPattern = RegExp(r'^tt\d{5,10}$');
  static final RegExp _blurayPattern = RegExp(r'\b(blu-?ray|bd|4k|uhd)\b');
  static final RegExp _dvdPattern = RegExp(r'\bdvd\b');

  static String _collapse(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _attribute(String value) => _collapse(value).toLowerCase();

  static String _trimRating(double rating) {
    final text = rating.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }
}
