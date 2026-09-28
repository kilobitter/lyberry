import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/providers/json.dart';

class _CachedToken {
  const _CachedToken({
    required this.fingerprint,
    required this.value,
    required this.expiresAt,
  });

  final String fingerprint;
  final String value;
  final DateTime expiresAt;

  bool isValidAt(DateTime now) => now.isBefore(expiresAt);
}

class _PendingToken {
  const _PendingToken(this.fingerprint, this.future);

  final String fingerprint;
  final Future<String> future;
}

/// Twitch app-access tokens for IGDB, cached in memory only.
///
/// The exchange is a form-encoded POST body (never a query string), concurrent
/// callers share one in-flight request, and the token is bound to a fingerprint
/// of the client credentials so a replacement or removal can never leave a
/// stale token behind. No secret, token or response body appears in a message,
/// a log or an exception.
class TwitchTokenClient {
  TwitchTokenClient({
    required GamesTransport transport,
    Clock? clock,
    this.timeout = GamesEndpointLimits.twitchTimeout,
    this.expirySkew = const Duration(seconds: 60),
  }) : _transport = transport,
       _clock = clock ?? const SystemClock();

  static const int maxBytes = 64 * 1024;

  final GamesTransport _transport;
  final Clock _clock;
  final Duration timeout;
  final Duration expirySkew;

  _CachedToken? _cached;
  _PendingToken? _pending;
  int _generation = 0;

  /// Current credential generation; an IGDB 401 only invalidates the token it
  /// actually used.
  int get generation => _generation;

  /// A cached or freshly exchanged token, or `null` when either credential is
  /// missing (in which case no request is made at all).
  Future<String?> tokenFor({
    required String clientId,
    required String clientSecret,
  }) async {
    final id = clientId.trim();
    final secret = clientSecret.trim();
    if (id.isEmpty || secret.isEmpty) return null;

    final fingerprint = '$id\u0000$secret';
    final cached = _cached;
    if (cached != null &&
        cached.fingerprint == fingerprint &&
        cached.isValidAt(_clock.nowUtc())) {
      return cached.value;
    }

    final pending = _pending;
    if (pending != null && pending.fingerprint == fingerprint) {
      return pending.future;
    }

    final generation = _generation;
    final future = _acquire(id, secret, fingerprint, generation);
    _pending = _PendingToken(fingerprint, future);
    try {
      return await future;
    } finally {
      if (identical(_pending?.future, future)) _pending = null;
    }
  }

  /// Drops any cached token and detaches a pending exchange.
  ///
  /// A pending exchange started before this call will not be cached, and an
  /// immediate retry with the same credentials starts its own exchange instead
  /// of joining the stale one.
  void invalidate() {
    _generation++;
    _cached = null;
    _pending = null;
  }

  /// Invalidates only when nothing has changed since [generation] was observed,
  /// so a stale 401 cannot discard a token acquired after a credential change.
  void invalidateIf({required int generation}) {
    if (_generation != generation) return;
    invalidate();
  }

  Future<String> _acquire(
    String clientId,
    String clientSecret,
    String fingerprint,
    int generation,
  ) async {
    final body = Uri(
      queryParameters: <String, String>{
        'client_id': clientId,
        'client_secret': clientSecret,
        'grant_type': 'client_credentials',
      },
    ).query;
    final response = await _transport.send(
      GamesRequest(
        endpoint: GamesEndpoint.twitchToken,
        uri: GamesEndpoint.twitchToken.uri(),
        headers: const <String, String>{},
        body: body,
        contentType: 'application/x-www-form-urlencoded',
      ),
      timeout: timeout,
      maxBytes: maxBytes,
    );

    if (response.statusCode != 200) {
      throw gamesStatusException(response.statusCode, 'Twitch');
    }
    final root = jsonMap(decodeGamesJson(response.body, 'Twitch'));
    final token = jsonString(root?['access_token']).trim();
    if (root == null || token.isEmpty) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'Twitch sent an unexpected token response.',
      );
    }
    // A token becomes an Authorization header later, so validate it here: a
    // control character would otherwise raise a FormatException that carries the
    // whole header value (and therefore the secret).
    if (token.length > maxTokenLength) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'Twitch sent an unusable token.',
      );
    }
    for (final rune in token.runes) {
      if (rune < 0x21 || rune == 0x7f) {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'Twitch sent an unusable token.',
        );
      }
    }
    final tokenType = jsonString(root['token_type']).trim().toLowerCase();
    if (tokenType.isNotEmpty && tokenType != 'bearer') {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'Twitch sent an unexpected token type.',
      );
    }
    final expiresIn = jsonInt(root['expires_in']);
    if (expiresIn == null || expiresIn <= 0) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'Twitch sent an unexpected token lifetime.',
      );
    }
    final now = _clock.nowUtc();
    // Never cache beyond the lifetime Twitch reported: a short-lived token is
    // used for only a fraction of its life, not for a padded minimum.
    final real = Duration(seconds: expiresIn > 86400 ? 86400 : expiresIn);
    final safety = real > const Duration(seconds: 300)
        ? expirySkew
        : Duration(seconds: real.inSeconds ~/ 5);
    final lifetime = real - safety;

    if (generation != _generation) {
      // Credentials changed while the exchange was in flight.
      throw const ProviderException(
        LookupFailureKind.unavailable,
        'The games credentials changed during the lookup.',
      );
    }
    _cached = _CachedToken(
      fingerprint: fingerprint,
      value: token,
      expiresAt: now.add(lifetime),
    );
    return token;
  }

  /// Longest token the client will accept; anything longer is refused rather
  /// than turned into a header.
  static const int maxTokenLength = 4096;
}
