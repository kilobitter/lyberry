import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/games/game_catalog.dart';
import 'package:lyberry/services/games/games_request_gate.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/games/igdb_client.dart';
import 'package:lyberry/services/games/scan_dex_client.dart';
import 'package:lyberry/services/games/twitch_token_client.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/lookup_cache.dart';

/// ScanDex identification plus IGDB metadata, as one games provider.
///
/// Barcode lookups go through [MetadataProvider]; title searches go through
/// [GameCatalog]. Both share one IGDB request gate (spacing, concurrency,
/// cooldown), one in-memory token and one credential generation, so a change in
/// Settings cannot leave stale work behind, start a new paid request, or let an
/// old request repopulate the cache.
class GamesLookupService implements MetadataProvider, GameCatalog {
  GamesLookupService({
    required ApiKeyStore keys,
    required GamesTransport transport,
    required GamesRequestGate gate,
    LookupCache? cache,
    Clock? clock,
  }) : _keys = keys,
       _transport = transport,
       _gate = gate,
       _cache = cache,
       _tokens = TwitchTokenClient(transport: transport, clock: clock);

  static const String providerId = 'igdb';
  static const String providerLabel = 'IGDB';
  static const int maxPlatformsPerGame = 8;
  static const int maxGameCandidates = 60;

  final ApiKeyStore _keys;
  final GamesTransport _transport;
  final GamesRequestGate _gate;
  final LookupCache? _cache;
  final TwitchTokenClient _tokens;

  int _generation = 0;

  /// Rate-limit status so Settings can show a games cooldown.
  Duration get cooldownRemaining => _gate.cooldownRemaining;

  @override
  String get id => providerId;

  @override
  String get label => providerLabel;

  @override
  Set<ProviderRole> get roles => const <ProviderRole>{ProviderRole.games};

  /// Games answer for an explicit game hint and for unknown non-ISBN codes;
  /// book/music/movie hints never reach this provider.
  @override
  bool supports(MediaType? mediumHint) =>
      mediumHint == null || mediumHint == MediaType.game;

  @override
  Future<bool> get isConfigured async {
    final credentials = await _twitchCredentials();
    return credentials.clientId.isNotEmpty &&
        credentials.clientSecret.isNotEmpty;
  }

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    final generation = _generation;
    final String? scanDexToken;
    try {
      scanDexToken = await _read(GamesKeyProvider.scandex);
    } on ProviderException catch (error) {
      // A keystore read failure is not a missing key: never tell the user to
      // add credentials they already stored.
      throw ProviderException(
        LookupFailureKind.unavailable,
        'ScanDex credentials could not be read on this device. ${error.message}',
      );
    }
    // The key read awaited: a credential change during it must abort before any
    // request is started.
    _assertCurrent(generation);
    if (scanDexToken == null || scanDexToken.trim().isEmpty) {
      // No request without credentials. An explicit game hint gets actionable
      // help; an unrelated automatic lookup stays silent.
      if (query.mediumHint == MediaType.game) {
        throw const ProviderException(
          LookupFailureKind.unavailable,
          'Add your ScanDex API token in Settings to identify game barcodes.',
        );
      }
      return ProviderLookupResult();
    }

    final client = ScanDexClient(transport: _transport, token: scanDexToken);
    final match = await client.lookup(query.identifier.value);
    _assertCurrent(generation);
    if (match == null) return ProviderLookupResult();

    final partial = _scanDexCandidate(match);
    final ({String clientId, String clientSecret}) credentials;
    try {
      credentials = await _twitchCredentials();
    } on ProviderException catch (error) {
      // A credential change during the read must not become a partial answer.
      _assertCurrent(generation);
      return ProviderLookupResult(
        candidates: <MetadataCandidate>[
          _scanDexCandidate(match, downgrade: true),
        ],
        warning: _warning(
          LookupFailureKind.unavailable,
          'Twitch credentials could not be read on this device '
          '(${error.message}). The ScanDex identification is shown as-is.',
        ),
      );
    }
    // The credential read awaited: never start a request or return a partial
    // with credentials that were replaced in the meantime.
    _assertCurrent(generation);
    if (credentials.clientId.isEmpty || credentials.clientSecret.isEmpty) {
      return ProviderLookupResult(
        candidates: <MetadataCandidate>[partial],
        warning: _warning(
          LookupFailureKind.unavailable,
          'Add your Twitch client ID and secret in Settings to load full IGDB '
          'details. The ScanDex identification is shown as-is.',
        ),
      );
    }

    final igdb = IgdbClient(
      transport: _transport,
      tokens: _tokens,
      credentials: _twitchCredentials,
      gate: _gate,
      isStale: () => _generation != generation,
    );
    // The platform came from ScanDex alone, so this candidate can never be an
    // exact match, and an invalidated operation is rejected rather than kept.
    MetadataCandidate downgraded() => _scanDexCandidate(match, downgrade: true);

    ProviderLookupResult partialResult(LookupFailureKind kind, String message) {
      if (_generation != generation) {
        throw const ProviderException(
          LookupFailureKind.unavailable,
          'The games credentials changed during the lookup.',
        );
      }
      return ProviderLookupResult(
        candidates: <MetadataCandidate>[downgraded()],
        warning: _warning(kind, message),
      );
    }

    try {
      final game = await igdb.gameById(match.igdbId);
      _assertCurrent(generation);
      if (game == null) {
        return partialResult(
          LookupFailureKind.unavailable,
          'IGDB has no record for this game yet; the ScanDex identification '
          'is shown as-is.',
        );
      }
      if (match.platformId != null &&
          game.platformById(match.platformId) == null) {
        // A platform mismatch must never silently become another console, and
        // it can no longer stay an exact match.
        return partialResult(
          LookupFailureKind.malformed,
          'IGDB does not list the ScanDex platform for this game, so the '
          'platform is unconfirmed. Pick the console in the editor.',
        );
      }
      return ProviderLookupResult(
        candidates: <MetadataCandidate>[_igdbCandidate(game, match)],
      );
    } on ProviderException catch (error) {
      // Trustworthy ScanDex fields stay usable when enrichment fails.
      if (_generation != generation) {
        throw const ProviderException(
          LookupFailureKind.unavailable,
          'The games credentials changed during the lookup.',
        );
      }
      if (match.title.trim().isEmpty) rethrow;
      return partialResult(error.kind, error.message);
    }
  }

  @override
  Future<GameSearchOutcome> searchByTitle(String title) async {
    final generation = _generation;
    final ({String clientId, String clientSecret}) credentials;
    try {
      credentials = await _twitchCredentials();
    } on ProviderException catch (error) {
      return GameSearchOutcome(
        failure: _failure(
          LookupFailureKind.unavailable,
          'Twitch credentials could not be read on this device '
          '(${error.message}).',
        ),
      );
    }
    if (credentials.clientId.isEmpty || credentials.clientSecret.isEmpty) {
      return GameSearchOutcome(
        failure: _failure(
          LookupFailureKind.unavailable,
          'Add your Twitch client ID and secret in Settings to search games by '
          'title.',
        ),
      );
    }

    final igdb = IgdbClient(
      transport: _transport,
      tokens: _tokens,
      credentials: _twitchCredentials,
      gate: _gate,
      isStale: () => _generation != generation,
    );
    try {
      final games = await igdb.searchByTitle(title);
      _assertCurrent(generation);
      return GameSearchOutcome(candidates: _titleCandidates(games));
    } on ProviderException catch (error) {
      return GameSearchOutcome(failure: _failure(error.kind, error.message));
    }
  }

  @override
  void invalidateCredentials() {
    _generation++;
    _tokens.invalidate();
    _cache?.clear();
  }

  Future<({String clientId, String clientSecret})> _twitchCredentials() async {
    final id = await _read(GamesKeyProvider.twitchId) ?? '';
    final secret = await _read(GamesKeyProvider.twitchSecret) ?? '';
    return (clientId: id, clientSecret: secret);
  }

  Future<String?> _read(GamesKeyProvider provider) async {
    try {
      return await _keys.read(provider);
    } on WebLookupException catch (error) {
      // Sanitized storage failure, never a "no key" answer.
      throw ProviderException(LookupFailureKind.unavailable, error.message);
    } on Object {
      throw ProviderException(
        LookupFailureKind.unavailable,
        '${provider.label} could not be read on this device.',
      );
    }
  }

  /// Throws when the credentials changed while an operation was in flight, so
  /// an old request can neither be accepted nor cached.
  void _assertCurrent(int generation) {
    if (generation != _generation) {
      // `unavailable`, not `cooldown`: a credential change must not penalize the
      // shared IGDB limiter as if it were a provider quota failure.
      throw const ProviderException(
        LookupFailureKind.unavailable,
        'The games credentials changed during the lookup.',
      );
    }
  }

  LookupFailure _warning(LookupFailureKind kind, String message) =>
      LookupFailure(
        providerId: providerId,
        providerLabel: providerLabel,
        kind: kind,
        message: message,
      );

  LookupFailure _failure(LookupFailureKind kind, String message) =>
      _warning(kind, message);

  /// Candidate built purely from ScanDex fields: useful when IGDB is missing,
  /// unavailable or disagrees about the platform.
  MetadataCandidate _scanDexCandidate(
    ScanDexMatch match, {
    bool downgrade = false,
  }) => MetadataCandidate(
    providerId: 'scandex',
    providerLabel: 'ScanDex',
    externalId: 'scandex:${match.igdbId}:${match.platformId ?? 'any'}',
    // A community entry is never exact, and a candidate whose platform came
    // from ScanDex alone is downgraded to a possible match.
    matchKind: !downgrade && match.isImported
        ? MatchKind.exact
        : MatchKind.possible,
    title: match.title,
    medium: MediaType.game,
    platform: match.platformName ?? '',
  );

  MetadataCandidate _igdbCandidate(IgdbGame game, ScanDexMatch match) {
    final platform =
        match.platformName ?? game.platformById(match.platformId)?.name ?? '';
    return MetadataCandidate(
      providerId: providerId,
      providerLabel: providerLabel,
      externalId: 'igdb:${game.id}:${match.platformId ?? 'any'}',
      matchKind: match.isImported ? MatchKind.exact : MatchKind.possible,
      title: game.name,
      medium: MediaType.game,
      creator: game.creator,
      year: game.yearFor(match.platformId),
      publisher: game.publisher,
      description: game.summary,
      platform: platform,
      coverUrl: game.coverUrl,
      sourceUrl: game.url.isEmpty ? null : game.url,
    );
  }

  /// One candidate per game+platform pair, capped and deduplicated.
  List<MetadataCandidate> _titleCandidates(List<IgdbGame> games) {
    final candidates = <MetadataCandidate>[];
    final seen = <String>{};
    for (final game in games) {
      if (candidates.length >= maxGameCandidates) break;
      if (game.platforms.isEmpty) {
        final externalId = 'igdb:${game.id}:any';
        if (seen.add(externalId)) {
          candidates.add(_titleCandidate(game, null, externalId, ''));
        }
        continue;
      }
      var count = 0;
      for (final platform in game.platforms) {
        if (count >= maxPlatformsPerGame) break;
        if (candidates.length >= maxGameCandidates) break;
        count++;
        final externalId = 'igdb:${game.id}:${platform.id}';
        if (seen.add(externalId)) {
          candidates.add(
            _titleCandidate(game, platform.id, externalId, platform.name),
          );
        }
      }
    }
    return candidates;
  }

  MetadataCandidate _titleCandidate(
    IgdbGame game,
    int? platformId,
    String externalId,
    String platformName,
  ) => MetadataCandidate(
    providerId: providerId,
    providerLabel: providerLabel,
    externalId: externalId,
    matchKind: MatchKind.possible,
    title: game.name,
    medium: MediaType.game,
    creator: game.creator,
    // A platform's own release year only; no year for a platform-less record.
    year: game.yearFor(platformId),
    publisher: game.publisher,
    description: game.summary,
    platform: platformName,
    coverUrl: game.coverUrl,
    sourceUrl: game.url.isEmpty ? null : game.url,
  );
}
