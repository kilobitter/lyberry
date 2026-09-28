import 'package:lyberry/domain/lookup.dart';

/// Result of one explicit movie title search: candidates plus an optional
/// sanitized failure.
class MovieSearchOutcome {
  MovieSearchOutcome({
    List<MetadataCandidate> candidates = const <MetadataCandidate>[],
    this.failure,
  }) : candidates = List<MetadataCandidate>.unmodifiable(candidates);

  final List<MetadataCandidate> candidates;
  final LookupFailure? failure;

  bool get hasCandidates => candidates.isNotEmpty;
}

/// Explicit, user-triggered movie title search.
///
/// Kept separate from [MetadataProvider] so the barcode path stays an ordinary
/// provider while the title path can be injected and tested on its own. A
/// future server-side proxy can implement the same interface.
abstract interface class MovieCatalog {
  /// True when the UPCMDB key needed for identification and title search is
  /// stored. Reading this performs no network request.
  Future<bool> get isConfigured;

  /// One search per call, bounded by the caller. [year] is optional and, when
  /// given, is a four-digit release year.
  Future<MovieSearchOutcome> searchByTitle(String title, {int? year});

  /// Drops the credential generation and any cached lookup after a key change,
  /// so a removed key can neither start nor publish a request.
  void invalidateCredentials();
}
