import 'package:lyberry/domain/lookup.dart';

/// Result of one explicit title search: candidates plus an optional warning.
class GameSearchOutcome {
  GameSearchOutcome({
    List<MetadataCandidate> candidates = const <MetadataCandidate>[],
    this.failure,
  }) : candidates = List<MetadataCandidate>.unmodifiable(candidates);

  final List<MetadataCandidate> candidates;
  final LookupFailure? failure;

  bool get hasCandidates => candidates.isNotEmpty;
}

/// Explicit, user-triggered game title search.
///
/// Kept separate from [MetadataProvider] so the barcode path stays an ordinary
/// provider while the title path can be injected and tested on its own. A
/// future server-side proxy can implement the same interface.
abstract interface class GameCatalog {
  /// True when the credentials needed for a title search are stored.
  Future<bool> get isConfigured;

  /// One search per call, bounded by the caller.
  Future<GameSearchOutcome> searchByTitle(String title);

  /// Drops cached tokens, cached lookups and any in-flight acceptance after a
  /// credential change.
  void invalidateCredentials();
}
