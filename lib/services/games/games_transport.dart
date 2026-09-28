import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/user_agent.dart';

/// The only HTTP methods the games clients may use.
enum GamesHttpMethod { get, post }

/// One fixed production endpoint.
///
/// The allowlist is by host *and* path *and* method, so a client cannot be
/// pointed at another route on the same host.
class GamesEndpoint {
  const GamesEndpoint({
    required this.host,
    required this.path,
    required this.method,
  });

  final String host;
  final String path;
  final GamesHttpMethod method;

  /// Stable allowlist key: `GET host/path`.
  String get key => '${method.name.toUpperCase()} $host$path';

  Uri uri([Map<String, String>? query]) => Uri.https(host, path, query);

  static const GamesEndpoint scanDexLookup = GamesEndpoint(
    host: 'scandex.gamery.app',
    path: '/api/v2/lookup',
    method: GamesHttpMethod.get,
  );

  static const GamesEndpoint twitchToken = GamesEndpoint(
    host: 'id.twitch.tv',
    path: '/oauth2/token',
    method: GamesHttpMethod.post,
  );

  static const GamesEndpoint igdbGames = GamesEndpoint(
    host: 'api.igdb.com',
    path: '/v4/games',
    method: GamesHttpMethod.post,
  );

  /// Every endpoint the app is allowed to call.
  static final Set<String> productionAllowlist = <String>{
    scanDexLookup.key,
    twitchToken.key,
    igdbGames.key,
  };
}

/// One request against an allowlisted endpoint.
class GamesRequest {
  const GamesRequest({
    required this.endpoint,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
    this.contentType = 'application/json',
  });

  final GamesEndpoint endpoint;
  final Uri uri;

  /// Extra headers, for example `Authorization` or `Client-ID`. They are never
  /// logged and are dropped on any redirect (redirects are disabled).
  final Map<String, String> headers;
  final String? body;
  final String contentType;
}

class GamesResponse {
  GamesResponse({
    required this.statusCode,
    required this.bytes,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(
         headers.map((key, value) => MapEntry(key.toLowerCase(), value)),
       );

  final int statusCode;
  final Uint8List bytes;
  final Map<String, String> headers;

  String? header(String name) => headers[name.toLowerCase()];

  String get body => utf8.decode(bytes, allowMalformed: true);
}

/// Injectable seam so tests can script responses without a socket.
abstract interface class GamesTransport {
  Future<GamesResponse> send(
    GamesRequest request, {
    required Duration timeout,
    required int maxBytes,
  });
}

/// Bounded HTTP for the fixed games endpoints.
///
/// HTTPS on port 443 only, path+method allowlisted, userinfo rejected, redirects
/// disabled (so credentials can never be replayed to another location), one
/// whole-request deadline, a body cap and sanitized errors that never echo a
/// response body, a URL query or a header value.
class IoGamesTransport implements GamesTransport {
  IoGamesTransport({
    required Set<String> allowedEndpoints,
    HttpClient Function()? clientFactory,
    bool allowInsecureTestUris = false,
  }) : _allowedEndpoints = allowedEndpoints,
       _clientFactory = clientFactory ?? HttpClient.new,
       _allowInsecureTestUris = allowInsecureTestUris;

  final Set<String> _allowedEndpoints;
  final HttpClient Function() _clientFactory;
  final bool _allowInsecureTestUris;

  static const int defaultMaxBytes = 1024 * 1024;
  static const Duration defaultTimeout = Duration(seconds: 15);

  @override
  Future<GamesResponse> send(
    GamesRequest request, {
    required Duration timeout,
    int maxBytes = defaultMaxBytes,
  }) async {
    final uri = request.uri;
    final testSeam = _allowInsecureTestUris && uri.scheme == 'http';
    if (uri.scheme != 'https' && !testSeam) {
      throw const ProviderException(
        LookupFailureKind.http,
        'Games lookups only use https.',
      );
    }
    if (!testSeam && uri.hasPort && uri.port != 443) {
      throw const ProviderException(
        LookupFailureKind.http,
        'Games lookups only use port 443.',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const ProviderException(
        LookupFailureKind.http,
        'Games lookups never carry credentials in the URL.',
      );
    }
    if (uri.host != request.endpoint.host ||
        uri.path != request.endpoint.path ||
        !_allowedEndpoints.contains(request.endpoint.key)) {
      throw const ProviderException(
        LookupFailureKind.http,
        'That games endpoint is not allowed.',
      );
    }
    if (timeout <= Duration.zero) {
      throw const ProviderException(
        LookupFailureKind.timeout,
        'The games request had no time left.',
      );
    }

    final client = _clientFactory();
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    void abort() {
      try {
        client.close(force: true);
      } on Object {
        // Closing twice is not interesting.
      }
    }

    try {
      final httpRequest = await client
          .openUrl(request.endpoint.method.name, uri)
          .timeout(remaining());
      httpRequest
        ..followRedirects = false
        ..persistentConnection = false;
      httpRequest.headers.set('accept', 'application/json');
      httpRequest.headers.set('user-agent', lyberryUserAgent());
      if (request.body != null) {
        httpRequest.headers.set('content-type', request.contentType);
      }
      for (final entry in request.headers.entries) {
        _validateHeaderValue(entry.value);
        httpRequest.headers.set(entry.key, entry.value);
      }
      final body = request.body;
      if (body != null) httpRequest.add(utf8.encode(body));

      final response = await httpRequest.close().timeout(remaining());
      final bytes = await _readBounded(
        response,
        maxBytes: maxBytes,
        remaining: remaining,
        abort: abort,
      );
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });
      return GamesResponse(
        statusCode: response.statusCode,
        bytes: bytes,
        headers: headers,
      );
    } on TimeoutException {
      abort();
      throw const ProviderException(
        LookupFailureKind.timeout,
        'A games service did not answer in time.',
      );
    } on ProviderException {
      abort();
      rethrow;
    } on HandshakeException {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'A games service certificate could not be verified.',
      );
    } on SocketException {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'A games service could not be reached.',
      );
    } on HttpException {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'A games service closed the connection early.',
      );
    } on FormatException {
      // Dart's HttpHeaders validation error includes the whole offending header
      // value, which can be a bearer token; never let it escape.
      abort();
      throw const ProviderException(
        LookupFailureKind.malformed,
        'A games request could not be encoded.',
      );
    } on Object {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'A games request failed.',
      );
    } finally {
      abort();
    }
  }

  /// Header values must be printable and bounded before Dart sees them.
  static void _validateHeaderValue(String value) {
    if (value.isEmpty || value.length > 4096) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'A games request header was rejected.',
      );
    }
    for (final rune in value.runes) {
      if (rune < 0x20 || rune == 0x7f) {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'A games request header was rejected.',
        );
      }
    }
  }

  Future<Uint8List> _readBounded(
    HttpClientResponse response, {
    required int maxBytes,
    required Duration Function() remaining,
    required void Function() abort,
  }) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    late StreamSubscription<List<int>> subscription;
    Timer? timer;
    var finished = false;

    void finish(FutureOr<void> Function() complete) {
      if (finished) return;
      finished = true;
      timer?.cancel();
      complete();
    }

    void fail(Object error) {
      finish(() {
        subscription.cancel();
        abort();
        if (!completer.isCompleted) completer.completeError(error);
      });
    }

    subscription = response.listen(
      (chunk) {
        if (finished) return;
        builder.add(chunk);
        if (builder.length > maxBytes) {
          fail(
            ProviderException(
              LookupFailureKind.malformed,
              'A games service answered with more than '
              '${maxBytes ~/ 1024} KiB.',
            ),
          );
        }
      },
      onError: (Object error) {
        fail(
          const ProviderException(
            LookupFailureKind.network,
            'A games service answer could not be read.',
          ),
        );
      },
      onDone: () {
        finish(() {
          if (!completer.isCompleted) completer.complete(builder.takeBytes());
        });
      },
      cancelOnError: true,
    );

    final left = remaining();
    if (left <= Duration.zero) {
      fail(
        const ProviderException(
          LookupFailureKind.timeout,
          'A games service did not finish in time.',
        ),
      );
    } else {
      timer = Timer(left, () {
        fail(
          const ProviderException(
            LookupFailureKind.timeout,
            'A games service did not finish in time.',
          ),
        );
      });
    }
    return completer.future;
  }
}

/// Status code to sanitized failure, shared by the games clients.
ProviderException gamesStatusException(int statusCode, String service) {
  if (statusCode == 401 || statusCode == 403) {
    return ProviderException(
      LookupFailureKind.http,
      '$service rejected the credentials. Check them in Settings.',
    );
  }
  if (statusCode == 429) {
    return ProviderException(
      LookupFailureKind.quota,
      '$service is rate limiting this device. Try again later.',
    );
  }
  if (statusCode >= 500) {
    return ProviderException(
      LookupFailureKind.unavailable,
      '$service reported an internal error.',
    );
  }
  return ProviderException(
    LookupFailureKind.http,
    '$service answered with status $statusCode.',
  );
}

/// Decodes a JSON value, mapping any parse problem to a sanitized failure.
Object? decodeGamesJson(String body, String service) {
  try {
    return jsonDecode(body);
  } on Object {
    throw ProviderException(
      LookupFailureKind.malformed,
      '$service sent a response Lyberry could not read.',
    );
  }
}

/// Contract timeouts for the games services.
abstract final class GamesEndpointLimits {
  static const Duration scanDexTimeout = Duration(seconds: 10);
  static const Duration twitchTimeout = Duration(seconds: 10);
  static const Duration igdbTimeout = Duration(seconds: 15);
}
