import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/games/games_request_gate.dart';
import 'package:lyberry/services/games/twitch_token_client.dart';
import 'package:lyberry/services/providers/json.dart';
import 'package:lyberry/services/transport.dart';

class IgdbPlatform {
  const IgdbPlatform({required this.id, required this.name});

  final int id;
  final String name;
}

/// One IGDB game with the fields Lyberry maps into a candidate.
class IgdbGame {
  const IgdbGame({
    required this.id,
    required this.name,
    this.url = '',
    this.summary = '',
    this.coverUrl,
    this.creator = '',
    this.publisher = '',
    this.platforms = const <IgdbPlatform>[],
    this.releaseYears = const <int, int>{},
  });

  final int id;
  final String name;
  final String url;
  final String summary;
  final String? coverUrl;
  final String creator;
  final String publisher;
  final List<IgdbPlatform> platforms;

  /// Release year per platform id. Never a guess from another platform.
  final Map<int, int> releaseYears;

  int? yearFor(int? platformId) {
    if (platformId == null) return null;
    return releaseYears[platformId];
  }

  IgdbPlatform? platformById(int? platformId) {
    if (platformId == null) return null;
    for (final platform in platforms) {
      if (platform.id == platformId) return platform;
    }
    return null;
  }
}

typedef TwitchCredentialsReader =
    Future<({String clientId, String clientSecret})> Function();

/// IGDB games endpoint client: fetch by exact id, or search by title.
///
/// A 401 triggers exactly one token refresh and one retry; there are no retry
/// loops. Every request passes the shared IGDB limiter, so barcode and title
/// lookups cannot exceed the contracted rate together.
class IgdbClient {
  IgdbClient({
    required GamesTransport transport,
    required TwitchTokenClient tokens,
    required TwitchCredentialsReader credentials,
    required GamesRequestGate gate,
    bool Function()? isStale,
    this.defaultCooldown = const Duration(seconds: 60),
    this.timeout = GamesEndpointLimits.igdbTimeout,
  }) : _transport = transport,
       _tokens = tokens,
       _credentials = credentials,
       _gate = gate,
       _isStale = isStale;

  static const int maxBytes = 512 * 1024;
  static const int maxTitleLength = 120;
  static const int defaultSearchLimit = 20;

  /// Explicit field list: no implicit IGDB defaults, so nothing unexpected is
  /// requested or mapped.
  static const String fields =
      'name,url,summary,cover.image_id,platforms.id,platforms.name,'
      'involved_companies.company.name,involved_companies.developer,'
      'involved_companies.publisher,release_dates.platform,'
      'release_dates.y,release_dates.date';

  final GamesTransport _transport;
  final TwitchTokenClient _tokens;
  final TwitchCredentialsReader _credentials;
  final GamesRequestGate _gate;
  final bool Function()? _isStale;
  final Duration defaultCooldown;
  final Duration timeout;

  /// True when the user has stored both Twitch credentials.
  Future<bool> get isConfigured async {
    final credentials = await _credentials();
    return credentials.clientId.trim().isNotEmpty &&
        credentials.clientSecret.trim().isNotEmpty;
  }

  Future<IgdbGame?> gameById(int id) async {
    final games = await _query('fields $fields; where id = $id; limit 1;');
    if (games.isEmpty) return null;
    for (final game in games) {
      if (game.id == id) return game;
    }
    // A different id is a malformed answer, never a silent substitution.
    throw const ProviderException(
      LookupFailureKind.malformed,
      'IGDB answered with a different game id.',
    );
  }

  /// Title search. Returns at most [limit] games; the caller decides how to
  /// group them by platform.
  Future<List<IgdbGame>> searchByTitle(
    String title, {
    int limit = defaultSearchLimit,
  }) async {
    final escaped = escapeApicalypseQuoted(title);
    if (escaped == null) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'Type a game title of up to $maxTitleLength characters.',
      );
    }
    final bounded = limit.clamp(1, defaultSearchLimit);
    return _query('search "$escaped"; fields $fields; limit $bounded;');
  }

  /// Validates and escapes one user-typed title for an APICalypse quoted
  /// string. Returns `null` when the input is unusable.
  static String? escapeApicalypseQuoted(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maxTitleLength) return null;
    for (final rune in trimmed.runes) {
      if (rune < 0x20 || rune == 0x7f) return null;
    }
    return trimmed.replaceAll('\\', r'\\').replaceAll('"', r'\"');
  }

  Future<List<IgdbGame>> _query(String query) async {
    _assertFresh();
    final credentials = await _credentials();
    _assertFresh();
    var token = await _tokens.tokenFor(
      clientId: credentials.clientId,
      clientSecret: credentials.clientSecret,
    );
    _assertFresh();
    if (token == null) {
      throw const ProviderException(
        LookupFailureKind.unavailable,
        'Add your Twitch client ID and secret in Settings to use IGDB.',
      );
    }

    var tokenGeneration = _tokens.generation;
    var response = await _post(query, credentials.clientId, token);
    if (response.statusCode == 401) {
      // Exactly one refresh and one retry, never a loop. The invalidation is
      // bound to the token generation this attempt used, so an old 401 cannot
      // discard a token acquired after a credential change.
      _tokens.invalidateIf(generation: tokenGeneration);
      _assertFresh();
      token = await _tokens.tokenFor(
        clientId: credentials.clientId,
        clientSecret: credentials.clientSecret,
      );
      _assertFresh();
      if (token == null) {
        throw const ProviderException(
          LookupFailureKind.unavailable,
          'Add your Twitch client ID and secret in Settings to use IGDB.',
        );
      }
      tokenGeneration = _tokens.generation;
      response = await _post(query, credentials.clientId, token);
    }
    if (response.statusCode != 200) {
      throw gamesStatusException(response.statusCode, 'IGDB');
    }

    final decoded = decodeGamesJson(response.body, 'IGDB');
    if (decoded is! List) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'IGDB sent an unexpected response shape.',
      );
    }
    final games = <IgdbGame>[];
    for (final entry in decoded) {
      final game = _gameFrom(entry);
      if (game != null) games.add(game);
    }
    return games;
  }

  Future<GamesResponse> _post(String query, String clientId, String token) {
    _assertFresh();
    // Spacing and the concurrency cap apply to every POST, including the 401
    // retry, so a slow token exchange cannot bunch later requests together.
    return _gate.run(() async {
      // Checked again *after* admission: a credential change while this request
      // was queued for a slot must not send with the old token.
      _assertFresh();
      final response = await _transport.send(
        GamesRequest(
          endpoint: GamesEndpoint.igdbGames,
          uri: GamesEndpoint.igdbGames.uri(),
          headers: <String, String>{
            'Client-ID': clientId,
            'Authorization': 'Bearer $token',
          },
          body: query,
          contentType: 'text/plain',
        ),
        timeout: timeout,
        maxBytes: maxBytes,
      );
      if (response.statusCode == 429) {
        // A cooldown taken here blocks both the barcode and the title path.
        _gate.penalize(
          parseRetryAfter(response.header('retry-after')) ?? defaultCooldown,
        );
      }
      return response;
    });
  }

  void _assertFresh() {
    if (_isStale?.call() ?? false) {
      // `unavailable`, not `cooldown`: MetadataService penalizes quota-style
      // failures on the shared IGDB limiter, and a credential change is not a
      // provider quota problem.
      throw const ProviderException(
        LookupFailureKind.unavailable,
        'The games credentials changed during the lookup.',
      );
    }
  }

  static IgdbGame? _gameFrom(Object? entry) {
    final root = jsonMap(entry);
    if (root == null) return null;
    final id = jsonInt(root['id']);
    final name = jsonString(root['name']).trim();
    if (id == null || id <= 0 || name.isEmpty) return null;

    final platforms = <IgdbPlatform>[];
    for (final entry in jsonList(root['platforms'])) {
      final platform = jsonMap(entry);
      if (platform == null) continue;
      final platformId = jsonInt(platform['id']);
      final platformName = jsonString(platform['name']).trim();
      if (platformId == null || platformId <= 0) continue;
      platforms.add(
        IgdbPlatform(
          id: platformId,
          name: platformName.isEmpty ? 'Platform $platformId' : platformName,
        ),
      );
    }

    // Platform-specific release years only: a date without a platform is not
    // attributed to a platform, and first_release_date is never used here.
    final years = <int, int>{};
    for (final entry in jsonList(root['release_dates'])) {
      final release = jsonMap(entry);
      if (release == null) continue;
      final platformId = jsonInt(release['platform']);
      final year = _releaseYear(release);
      if (platformId == null || platformId <= 0) continue;
      if (year == null || year < 1 || year > 9999) continue;
      years.putIfAbsent(platformId, () => year);
    }

    var creator = '';
    var publisher = '';
    for (final entry in jsonList(root['involved_companies'])) {
      final company = jsonMap(entry);
      if (company == null) continue;
      final name = jsonString(jsonMap(company['company'])?['name']).trim();
      if (name.isEmpty) continue;
      if (creator.isEmpty && company['developer'] == true) creator = name;
      if (publisher.isEmpty && company['publisher'] == true) publisher = name;
    }

    return IgdbGame(
      id: id,
      name: name,
      url: _safeIgdbUrl(jsonString(root['url'])),
      summary: jsonString(root['summary']).trim(),
      coverUrl: coverUrlFromImageId(
        jsonString(jsonMap(root['cover'])?['image_id']),
      ),
      creator: creator,
      publisher: publisher,
      platforms: List<IgdbPlatform>.unmodifiable(platforms),
      releaseYears: Map<int, int>.unmodifiable(years),
    );
  }

  static String _safeIgdbUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https') return '';
    if (uri.userInfo.isNotEmpty) return '';
    if (uri.hasPort && uri.port != 443) return '';
    final host = uri.host.toLowerCase();
    if (host != 'igdb.com' && !host.endsWith('.igdb.com')) return '';
    return uri.toString();
  }

  /// Release year for one platform.
  ///
  /// `y` wins when present; otherwise a Unix-seconds `date` is converted in UTC
  /// (an epoch number must never be read as a year), and strings that are not
  /// dates stay empty rather than guessed.
  static int? _releaseYear(Map<String, Object?> release) {
    final explicit = jsonInt(release['y']);
    if (explicit != null && explicit >= 1 && explicit <= 9999) {
      return explicit;
    }
    final epoch = jsonInt(release['date']);
    if (epoch != null && epoch > 0) {
      // Guard the conversion: a malformed huge value must not throw.
      const maxEpochSeconds = 253402300799; // 9999-12-31T23:59:59Z
      if (epoch > maxEpochSeconds) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
      if (at.year >= 1970 && at.year <= 9999) return at.year;
    }
    return null;
  }

  /// Builds a cover URL only from a validated `image_id`; anything else stays
  /// null so the medium placeholder is used.
  static String? coverUrlFromImageId(String imageId) {
    final trimmed = imageId.trim();
    if (trimmed.isEmpty || trimmed.length > 64) return null;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(trimmed)) return null;
    return 'https://images.igdb.com/igdb/image/upload/t_cover_big/$trimmed.jpg';
  }
}
