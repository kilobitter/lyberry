import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/media_type.dart';

/// How closely a candidate matches the searched code. There are no invented
/// percentage scores.
enum MatchKind {
  exact('Exact code match'),
  possible('Possible match');

  const MatchKind(this.label);

  final String label;
}

/// One provider result, always editable and never saved automatically.
class MetadataCandidate {
  const MetadataCandidate({
    required this.providerId,
    required this.providerLabel,
    required this.externalId,
    required this.matchKind,
    required this.title,
    this.medium,
    this.creator = '',
    this.year,
    this.publisher = '',
    this.description = '',
    this.platform = '',
    this.format = '',
    this.edition = '',
    this.coverUrl,
    this.sourceUrl,
  });

  final String providerId;
  final String providerLabel;
  final String externalId;
  final MatchKind matchKind;
  final String title;
  final MediaType? medium;
  final String creator;
  final int? year;
  final String publisher;
  final String description;

  /// Games use [platform]; movie releases use [format] for the release/edition
  /// label (for example `DVD` or `4K UHD + Blu-ray`). Both stay editable and
  /// neither is invented.
  final String platform;

  /// Release or edition label for media that carry one. Empty when the provider
  /// did not state a format.
  final String format;

  /// Extra release detail that distinguishes editions of the same title (for
  /// example `4K Ultra HD + Blu-ray (Repackaged)`). Empty when the provider did
  /// not state one.
  final String edition;

  /// Public HTTPS cover art, downloaded only after the user picks the candidate.
  final String? coverUrl;

  /// Public HTTPS page describing the record, kept as provenance.
  final String? sourceUrl;

  /// Stable identity for deduplication across the same provider.
  String get key => '$providerId:$externalId';

  /// One-line summary for the candidate list.
  String get subtitle {
    final parts = <String>[
      if (creator.trim().isNotEmpty) creator.trim(),
      if (year != null) '$year',
      if (medium != null) medium!.label,
    ];
    return parts.join(' | ');
  }
}

/// A normalized identifier plus an optional medium hint from the scanner.
class LookupQuery {
  const LookupQuery({required this.identifier, this.mediumHint});

  final NormalizedIdentifier identifier;
  final MediaType? mediumHint;

  String get cacheKey =>
      '${identifier.canonicalKey}|${mediumHint?.wireValue ?? 'any'}';
}

enum LookupFailureKind {
  network('Network unavailable'),
  timeout('Timed out'),
  http('Service error'),
  malformed('Unexpected response'),
  unavailable('Unavailable'),
  cooldown('Cooling down'),
  quota('Lookup quota reached');

  const LookupFailureKind(this.label);

  final String label;
}

/// A provider that could not answer; other providers still provide results.
class LookupFailure {
  const LookupFailure({
    required this.providerId,
    required this.providerLabel,
    required this.kind,
    required this.message,
    this.retryAfter,
  });

  final String providerId;
  final String providerLabel;
  final LookupFailureKind kind;
  final String message;
  final Duration? retryAfter;
}

/// Raised by a provider adapter; the service converts it into a [LookupFailure].
class ProviderException implements Exception {
  const ProviderException(this.kind, this.message, {this.retryAfter});

  final LookupFailureKind kind;
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => 'ProviderException(${kind.name}): $message';
}

/// A replaceable metadata source.
enum ProviderRole {
  /// Dedicated book catalogue (Open Library).
  books,

  /// Dedicated release/music catalogue (MusicBrainz).
  music,

  /// General fallback catalogue (UPCitemdb).
  general,

  /// Dedicated game catalogue (ScanDex identification plus IGDB metadata).
  games,

  /// Dedicated movie catalogue (UPCMDB identification and title search).
  movies,
}

abstract interface class MetadataProvider {
  String get id;
  String get label;

  /// Routing roles; a provider with no role is always queried first.
  Set<ProviderRole> get roles;

  /// Whether this provider can answer for the given medium hint.
  bool supports(MediaType? mediumHint);

  /// Returns candidates (possibly with a partial warning), or throws
  /// [ProviderException] for a real failure. An empty candidate list means
  /// "no match", which is different from an error.
  Future<ProviderLookupResult> lookup(LookupQuery query);
}

/// One provider's answer: usable candidates plus an optional partial warning,
/// for example when an edition record was found but a second request failed.
class ProviderLookupResult {
  ProviderLookupResult({
    List<MetadataCandidate> candidates = const <MetadataCandidate>[],
    this.warning,
  }) : candidates = List<MetadataCandidate>.unmodifiable(candidates);

  final List<MetadataCandidate> candidates;
  final LookupFailure? warning;
}

/// Everything one lookup produced, successes and partial failures.
class LookupOutcome {
  LookupOutcome({
    required List<MetadataCandidate> candidates,
    required List<LookupFailure> failures,
    required List<String> queriedProviders,
    this.fromCache = false,
  }) : candidates = List<MetadataCandidate>.unmodifiable(candidates),
       failures = List<LookupFailure>.unmodifiable(failures),
       queriedProviders = List<String>.unmodifiable(queriedProviders);

  final List<MetadataCandidate> candidates;
  final List<LookupFailure> failures;
  final List<String> queriedProviders;
  final bool fromCache;

  bool get hasCandidates => candidates.isNotEmpty;

  /// True when every queried provider errored, so the UI can offer a retry
  /// instead of claiming there is no match.
  bool get allProvidersFailed =>
      candidates.isEmpty &&
      failures.isNotEmpty &&
      failures.length >= queriedProviders.length;
}
