import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/user_agent.dart';

/// The only HTTP method the UPCMDB client may use.
enum MoviesHttpMethod { get }

/// One fixed UPCMDB endpoint, addressed by a literal path template.
///
/// The allowlist is by host *and* path *and* method, and the single dynamic
/// segment may only be a fixed-length digit code, so neither a client bug nor a
/// service-supplied value can point the request at another route on the same
/// host. The API key travels in a header and never in the URL.
class MoviesEndpoint {
  const MoviesEndpoint({
    required this.host,
    required this.pathTemplate,
    this.method = MoviesHttpMethod.get,
    this.codeLength = 0,
    this.queryKeys = const <String>{},
  });

  final String host;

  /// For example `/api/v1/lookup/:upc`. The single `:name` segment is replaced by
  /// the validated code.
  final String pathTemplate;
  final MoviesHttpMethod method;

  /// Required digit length of the code segment, or `0` when there is none.
  final int codeLength;

  /// The only query parameters this route accepts.
  final Set<String> queryKeys;

  /// Stable allowlist key: `GET host/path`.
  String get key => '${method.name.toUpperCase()} $host$pathTemplate';

  /// Builds the only URI this endpoint may use.
  ///
  /// Throws a sanitized failure instead of returning a URI the transport would
  /// have to reject later.
  Uri uri({
    String? code,
    Map<String, String> query = const <String, String>{},
  }) {
    for (final key in query.keys) {
      if (!queryKeys.contains(key)) {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'A movie lookup parameter was rejected before the request.',
        );
      }
    }
    return Uri.https(host, _pathFor(code), query.isEmpty ? null : query);
  }

  /// True when [uri] is exactly this route: fixed HTTPS host, no userinfo, no
  /// non-443 port, the literal path with a valid code segment and only the
  /// documented query parameters.
  bool matches(Uri uri, {bool allowInsecure = false}) {
    final schemeOk = allowInsecure
        ? uri.scheme == 'https' || uri.scheme == 'http'
        : uri.scheme == 'https';
    if (!schemeOk) return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (!allowInsecure && uri.hasPort && uri.port != 443) return false;
    if (uri.host != host) return false;
    if (!_matchesPath(uri.path)) return false;
    for (final key in uri.queryParameters.keys) {
      if (!queryKeys.contains(key)) return false;
    }
    return true;
  }

  String _pathFor(String? code) {
    if (codeLength == 0) {
      if (code != null) {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'A movie lookup code was rejected before the request.',
        );
      }
      return pathTemplate;
    }
    if (code == null || code.length != codeLength || !_isDigits(code)) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'A movie lookup code was rejected before the request.',
      );
    }
    return pathTemplate.replaceFirst(_codeSegment, code);
  }

  bool _matchesPath(String path) {
    if (codeLength == 0) return path == pathTemplate;
    final prefix = pathTemplate.replaceFirst(_codeSegment, '');
    if (!path.startsWith(prefix)) return false;
    final code = path.substring(prefix.length);
    return code.length == codeLength && _isDigits(code);
  }

  static final RegExp _codeSegment = RegExp(r':\w+');

  /// The documented API base host and prefix. The site's marketing example
  /// (`upcmdb.com/api/v1/...`) is not the detailed API reference base; the
  /// reference base is this Cloud Functions host with the `/api` prefix.
  static const String productionHost =
      'us-central1-upcmdb-cbae5.cloudfunctions.net';

  /// `GET /api/v1/lookup/:upc` for UPC-12 codes.
  static const MoviesEndpoint upcLookup = MoviesEndpoint(
    host: productionHost,
    pathTemplate: '/api/v1/lookup/:upc',
    codeLength: 12,
  );

  /// `GET /api/v1/lookup/ean/:ean` for EAN-13 codes.
  static const MoviesEndpoint eanLookup = MoviesEndpoint(
    host: productionHost,
    pathTemplate: '/api/v1/lookup/ean/:ean',
    codeLength: 13,
  );

  /// `GET /api/v1/search?title=...&year=...` for explicit movie title search.
  static const MoviesEndpoint titleSearch = MoviesEndpoint(
    host: productionHost,
    pathTemplate: '/api/v1/search',
    queryKeys: <String>{'title', 'year'},
  );

  /// Every endpoint the shipped app may call.
  static final Set<String> productionAllowlist = <String>{
    upcLookup.key,
    eanLookup.key,
    titleSearch.key,
  };
}

/// One request against an allowlisted endpoint.
class MoviesRequest {
  const MoviesRequest({
    required this.endpoint,
    required this.uri,
    this.headers = const <String, String>{},
  });

  final MoviesEndpoint endpoint;
  final Uri uri;

  /// Extra headers such as `x-api-key`. They are never logged and are dropped on
  /// any redirect (redirects are disabled).
  final Map<String, String> headers;
}

class MoviesResponse {
  MoviesResponse({
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
abstract interface class MoviesTransport {
  Future<MoviesResponse> get(
    MoviesRequest request, {
    required Duration timeout,
    required int maxBytes,
  });
}

/// Bounded HTTP for the fixed UPCMDB endpoints.
///
/// HTTPS on port 443 only, path+method allowlisted, userinfo rejected,
/// redirects disabled (so the API key can never be replayed to another
/// location), one whole-request deadline covering headers and body, a body cap
/// and sanitized errors that never echo a response body, a URL query or a
/// header value.
class IoMoviesTransport implements MoviesTransport {
  IoMoviesTransport({
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
  Future<MoviesResponse> get(
    MoviesRequest request, {
    Duration timeout = defaultTimeout,
    int maxBytes = defaultMaxBytes,
  }) async {
    final uri = request.uri;
    final testSeam = _allowInsecureTestUris && uri.scheme == 'http';
    if (uri.scheme != 'https' && !testSeam) {
      throw const ProviderException(
        LookupFailureKind.http,
        'Movie lookups only use https.',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const ProviderException(
        LookupFailureKind.http,
        'Movie lookups never carry credentials in the URL.',
      );
    }
    if (!testSeam && uri.hasPort && uri.port != 443) {
      throw const ProviderException(
        LookupFailureKind.http,
        'Movie lookups only use port 443.',
      );
    }
    // The allowlist and the path/route check apply in tests too: the seam only
    // relaxes the scheme and port for a loopback server.
    if (!_allowedEndpoints.contains(request.endpoint.key) ||
        !request.endpoint.matches(uri, allowInsecure: testSeam)) {
      throw const ProviderException(
        LookupFailureKind.http,
        'That movie endpoint is not allowed.',
      );
    }
    if (timeout <= Duration.zero) {
      throw const ProviderException(
        LookupFailureKind.timeout,
        'The movie request had no time left.',
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
      for (final entry in request.headers.entries) {
        _validateHeaderValue(entry.value);
        httpRequest.headers.set(entry.key, entry.value);
      }

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
      return MoviesResponse(
        statusCode: response.statusCode,
        bytes: bytes,
        headers: headers,
      );
    } on TimeoutException {
      abort();
      throw const ProviderException(
        LookupFailureKind.timeout,
        'UPCMDB did not answer in time.',
      );
    } on ProviderException {
      abort();
      rethrow;
    } on HandshakeException {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'The UPCMDB certificate could not be verified.',
      );
    } on SocketException {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'UPCMDB could not be reached.',
      );
    } on HttpException {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'UPCMDB closed the connection early.',
      );
    } on FormatException {
      // Dart's HttpHeaders validation error includes the whole offending header
      // value, which can be an API key; never let it escape.
      abort();
      throw const ProviderException(
        LookupFailureKind.malformed,
        'A movie request could not be encoded.',
      );
    } on Object {
      abort();
      throw const ProviderException(
        LookupFailureKind.network,
        'A movie request failed.',
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
        'A movie request header was rejected.',
      );
    }
    for (final rune in value.runes) {
      if (rune < 0x20 || rune == 0x7f) {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'A movie request header was rejected.',
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
              'UPCMDB answered with more than ${maxBytes ~/ 1024} KiB.',
            ),
          );
        }
      },
      onError: (Object error) {
        fail(
          const ProviderException(
            LookupFailureKind.network,
            'The UPCMDB answer could not be read.',
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
          'UPCMDB did not finish in time.',
        ),
      );
    } else {
      timer = Timer(left, () {
        fail(
          const ProviderException(
            LookupFailureKind.timeout,
            'UPCMDB did not finish in time.',
          ),
        );
      });
    }
    return completer.future;
  }
}

/// Status code to sanitized failure, shared by the UPCMDB calls.
///
/// 404 is handled by the caller as "no match"; 401/403 become key/access
/// guidance; 429 becomes a quota failure with the bounded `Retry-After`.
ProviderException upcMdbStatusException(int statusCode, {String? retryAfter}) {
  if (statusCode == 401) {
    return const ProviderException(
      LookupFailureKind.http,
      'UPCMDB rejected the API key. Check it in Settings.',
    );
  }
  if (statusCode == 403) {
    return const ProviderException(
      LookupFailureKind.http,
      'This UPCMDB key has no access to that endpoint. Check the plan and '
      'permissions in Settings.',
    );
  }
  if (statusCode == 429) {
    return ProviderException(
      LookupFailureKind.quota,
      'UPCMDB is rate limiting this device. Try again later.',
      retryAfter: parseBoundedRetryAfter(retryAfter),
    );
  }
  if (statusCode >= 500) {
    return const ProviderException(
      LookupFailureKind.unavailable,
      'UPCMDB reported an internal error.',
    );
  }
  return ProviderException(
    LookupFailureKind.http,
    'UPCMDB answered with status $statusCode.',
  );
}

/// Longest server cooldown Lyberry will honour, so a hostile or broken header
/// cannot park the provider for an unbounded time.
const Duration maxRetryAfter = Duration(minutes: 30);

/// Parses a `Retry-After` delta-seconds header, bounded and never throwing.
Duration? parseBoundedRetryAfter(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final seconds = int.tryParse(text);
  if (seconds == null || seconds <= 0) return null;
  final clamped = seconds > maxRetryAfter.inSeconds
      ? maxRetryAfter
      : Duration(seconds: seconds);
  return clamped;
}

/// Decodes a JSON value, mapping any parse problem to a sanitized failure.
Object? decodeMoviesJson(String body) {
  try {
    return jsonDecode(body);
  } on Object {
    throw const ProviderException(
      LookupFailureKind.malformed,
      'UPCMDB sent a response Lyberry could not read.',
    );
  }
}

bool _isDigits(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return value.isNotEmpty;
}

/// Contract limits for UPCMDB.
abstract final class MoviesEndpointLimits {
  /// One whole-request deadline for identification and title search.
  static const Duration requestTimeout = Duration(seconds: 15);

  /// Lyberry's own conservative spacing between UPCMDB requests.
  static const Duration minRequestInterval = Duration(seconds: 1);
}
