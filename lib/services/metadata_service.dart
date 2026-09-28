import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/rate_limiter.dart';

/// Coordinates providers: routing, partial failures, ranking and caching.
///
/// Providers throttle themselves at the request boundary, so a provider that is
/// cooling down answers immediately with a typed failure instead of holding the
/// whole lookup open. A lookup with any warning or failure is not cached, so a
/// retry can reach the provider that failed.
class MetadataService {
  MetadataService({
    required List<MetadataProvider> providers,
    Map<String, ProviderRateLimiter> limiters =
        const <String, ProviderRateLimiter>{},
    LookupCache? cache,
    this.defaultCooldown = const Duration(seconds: 60),
  }) : _providers = List<MetadataProvider>.unmodifiable(providers),
       _limiters = limiters,
       _cache = cache ?? LookupCache();

  final List<MetadataProvider> _providers;
  final Map<String, ProviderRateLimiter> _limiters;
  final LookupCache _cache;
  final Duration defaultCooldown;

  List<MetadataProvider> get providers => _providers;

  /// Rate-limit status for the UI, e.g. "UPCitemdb cooling down for 40s".
  Duration cooldownFor(String providerId) =>
      _limiters[providerId]?.cooldownRemaining ?? Duration.zero;

  /// Drops every cached lookup. Used when credentials change, so a stale empty
  /// or full answer can never be served for the new credentials.
  void invalidateCache() {
    _generation++;
    _cache.clear();
  }

  /// Bumped on every credential change; an in-flight answer from before the
  /// change is never accepted into the cache.
  int _generation = 0;

  Future<LookupOutcome> lookup(LookupQuery query) async {
    final generation = _generation;
    final cached = _cache.get(query.cacheKey);
    if (cached != null) {
      return LookupOutcome(
        candidates: cached,
        failures: const <LookupFailure>[],
        queriedProviders: const <String>[],
        fromCache: true,
      );
    }

    final stages = _route(query);
    final candidates = <MetadataCandidate>[];
    final failures = <LookupFailure>[];
    final queried = <String>[];
    final seen = <String>{};
    final order = <String, int>{};
    var orderIndex = 0;

    for (final stage in stages) {
      if (candidates.isNotEmpty) break; // a fallback runs only when needed
      final results = await Future.wait(
        stage.map((provider) => _run(provider, query)),
      );
      for (final result in results) {
        queried.add(result.provider.id);
        order.putIfAbsent(result.provider.id, () => orderIndex++);
        final warning = result.warning;
        if (warning != null) failures.add(warning);
        final failure = result.failure;
        if (failure != null) failures.add(failure);
        for (final candidate in result.candidates) {
          if (seen.add(candidate.key)) candidates.add(candidate);
        }
      }
    }

    candidates.sort((a, b) {
      if (a.matchKind != b.matchKind) {
        return a.matchKind.index - b.matchKind.index;
      }
      return (order[a.providerId] ?? 99).compareTo(order[b.providerId] ?? 99);
    });

    // Only a clean answer is cached: a completion that lost a provider (or kept
    // a warning) must be reachable again on retry.
    // Only a clean answer from the current credential generation is cached: a
    // lookup that started before the change must not hide the new state.
    if (failures.isEmpty && generation == _generation) {
      _cache.put(query.cacheKey, candidates);
    }

    return LookupOutcome(
      candidates: candidates,
      failures: failures,
      queriedProviders: queried,
    );
  }

  /// Primary providers first; the general fallback only runs when the primary
  /// stage produced nothing usable.
  List<List<MetadataProvider>> _route(LookupQuery query) {
    final hint = query.mediumHint;
    final books = _role(ProviderRole.books, hint);
    final music = _role(ProviderRole.music, hint);
    final games = _role(ProviderRole.games, hint);
    // An ISBN is never a movie code, whatever hint came with it, so the movie
    // catalogue is dropped before it can spend quota on a book.
    final movies = query.identifier.isIsbn
        ? const <MetadataProvider>[]
        : _role(ProviderRole.movies, hint);
    final general = _role(ProviderRole.general, hint);
    final extra = _providers
        .where((provider) => provider.roles.isEmpty && provider.supports(hint))
        .toList(growable: false);

    final List<MetadataProvider> primary;
    switch (hint) {
      case MediaType.book:
        primary = books;
      case MediaType.cd:
      case MediaType.vinyl:
        primary = music;
      case MediaType.dvd:
      case MediaType.bluray:
        // Dedicated movie catalogues answer first; the general fallback only
        // runs when they produced nothing (or are not configured).
        primary = movies;
      case MediaType.game:
        // Dedicated games providers answer for a game hint; the general
        // fallback only runs when they produced nothing.
        primary = games;
      case null:
        // An ISBN always auto-routes to books; any other unknown code may be a
        // game or a movie, so games, music and movies answer before the general
        // fallback.
        primary = query.identifier.isIsbn
            ? books
            : <MetadataProvider>[...games, ...music, ...movies];
    }

    final primaryWithExtra = <MetadataProvider>[...primary, ...extra];
    final used = <String>{for (final provider in primaryWithExtra) provider.id};
    final fallback = <MetadataProvider>[
      for (final provider in <MetadataProvider>[...general, ...books, ...music])
        if (!used.contains(provider.id)) provider,
    ];

    return <List<MetadataProvider>>[
      if (primaryWithExtra.isNotEmpty) primaryWithExtra,
      if (fallback.isNotEmpty) fallback,
    ];
  }

  List<MetadataProvider> _role(ProviderRole role, MediaType? hint) => _providers
      .where(
        (provider) => provider.roles.contains(role) && provider.supports(hint),
      )
      .toList(growable: false);

  Future<_ProviderResult> _run(
    MetadataProvider provider,
    LookupQuery query,
  ) async {
    final limiter = _limiters[provider.id];
    try {
      final result = await provider.lookup(query);
      return _ProviderResult(
        provider: provider,
        candidates: result.candidates,
        warning: result.warning,
      );
    } on ProviderException catch (error) {
      // Only quota-style answers park a provider; a transient network error must
      // not block the next retry.
      if (error.kind == LookupFailureKind.quota ||
          error.kind == LookupFailureKind.cooldown) {
        limiter?.penalize(error.retryAfter ?? defaultCooldown);
      }
      return _ProviderResult(
        provider: provider,
        candidates: const <MetadataCandidate>[],
        failure: LookupFailure(
          providerId: provider.id,
          providerLabel: provider.label,
          kind: error.kind,
          message: error.message,
          retryAfter: error.retryAfter,
        ),
      );
    } on Object catch (error) {
      return _ProviderResult(
        provider: provider,
        candidates: const <MetadataCandidate>[],
        failure: LookupFailure(
          providerId: provider.id,
          providerLabel: provider.label,
          kind: LookupFailureKind.malformed,
          message: 'Unexpected provider problem: $error',
        ),
      );
    }
  }
}

class _ProviderResult {
  const _ProviderResult({
    required this.provider,
    required this.candidates,
    this.failure,
    this.warning,
  });

  final MetadataProvider provider;
  final List<MetadataCandidate> candidates;
  final LookupFailure? failure;
  final LookupFailure? warning;
}
