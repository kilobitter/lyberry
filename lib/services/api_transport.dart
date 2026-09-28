import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyberry/domain/web_lookup.dart';

/// One bounded JSON API call. Keys travel in headers and are never logged.
class ApiRequest {
  const ApiRequest({
    required this.uri,
    required this.body,
    this.bearerToken,
    this.accept = 'application/json',
  });

  final Uri uri;
  final Map<String, Object?> body;
  final String? bearerToken;
  final String accept;

  String get encodedBody => jsonEncode(body);
}

class ApiResponse {
  const ApiResponse({required this.statusCode, required this.bytes});

  final int statusCode;
  final Uint8List bytes;

  String get body => utf8.decode(bytes, allowMalformed: true);
}

/// Bounded POST used by the paid providers.
abstract interface class ApiTransport {
  Future<ApiResponse> post(
    ApiRequest request, {
    required Duration timeout,
    required int maxBytes,
  });
}

/// Real transport with a fixed host allowlist, HTTPS only, no redirects and one
/// overall deadline covering connect, headers and body.
///
/// Errors are mapped to [WebLookupException] with sanitized messages: raw
/// response bodies and headers never reach the caller or any log.
class IoApiTransport implements ApiTransport {
  IoApiTransport({
    required this.allowedHosts,
    HttpClient Function()? clientFactory,
    bool allowInsecureTestUris = false,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _allowInsecureTestUris = allowInsecureTestUris;

  final Set<String> allowedHosts;
  final HttpClient Function() _clientFactory;

  /// Test-only seam for local in-process HTTP servers.
  final bool _allowInsecureTestUris;

  static const int tavilyMaxBytes = 1024 * 1024;
  static const int deepSeekMaxBytes = 128 * 1024;
  static const Duration callTimeout = Duration(seconds: 30);

  @override
  Future<ApiResponse> post(
    ApiRequest request, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    final uri = request.uri;
    final schemeAllowed =
        uri.scheme == 'https' ||
        (_allowInsecureTestUris && uri.scheme == 'http');
    if (!schemeAllowed) {
      throw const WebLookupException(
        WebFailureKind.unavailable,
        'Only https API endpoints are allowed.',
        stage: WebLookupStage.search,
      );
    }
    if (!allowedHosts.contains(uri.host.toLowerCase())) {
      throw const WebLookupException(
        WebFailureKind.unavailable,
        'This API host is not allowed.',
        stage: WebLookupStage.search,
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const WebLookupException(
        WebFailureKind.unavailable,
        'API URLs must not carry credentials.',
        stage: WebLookupStage.search,
      );
    }
    if (timeout <= Duration.zero) {
      throw const WebLookupException(
        WebFailureKind.timeout,
        'The request had no time left.',
        stage: WebLookupStage.search,
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
        // Closing an already-closed client is not interesting.
      }
    }

    try {
      final bytes = utf8.encode(request.encodedBody);
      final httpRequest = await client.postUrl(uri).timeout(remaining());
      httpRequest.followRedirects = false;
      httpRequest.headers.set('accept', request.accept);
      httpRequest.headers.set('content-type', 'application/json');
      final token = request.bearerToken;
      if (token != null && token.isNotEmpty) {
        httpRequest.headers.set('authorization', 'Bearer $token');
      }
      httpRequest.add(bytes);
      final response = await httpRequest.close().timeout(remaining());
      final body = await _readBounded(
        response,
        maxBytes: maxBytes,
        remaining: remaining,
        abort: abort,
      );
      return ApiResponse(statusCode: response.statusCode, bytes: body);
    } on TimeoutException {
      abort();
      throw WebLookupException(
        WebFailureKind.timeout,
        'No complete answer within ${timeout.inSeconds}s.',
        stage: WebLookupStage.search,
      );
    } on WebLookupException {
      abort();
      rethrow;
    } on SocketException {
      abort();
      throw const WebLookupException(
        WebFailureKind.network,
        'The service could not be reached.',
        stage: WebLookupStage.search,
      );
    } on HandshakeException {
      abort();
      throw const WebLookupException(
        WebFailureKind.network,
        'The secure connection failed.',
        stage: WebLookupStage.search,
      );
    } on HttpException {
      abort();
      throw const WebLookupException(
        WebFailureKind.network,
        'The service closed the connection early.',
        stage: WebLookupStage.search,
      );
    } finally {
      abort();
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
            WebLookupException(
              WebFailureKind.malformed,
              'The answer was larger than ${maxBytes ~/ 1024} KiB.',
              stage: WebLookupStage.extraction,
            ),
          );
        }
      },
      onError: (Object error) {
        fail(
          const WebLookupException(
            WebFailureKind.network,
            'The answer could not be read.',
            stage: WebLookupStage.extraction,
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
        const WebLookupException(
          WebFailureKind.timeout,
          'The answer did not finish in time.',
          stage: WebLookupStage.extraction,
        ),
      );
    } else {
      timer = Timer(left, () {
        fail(
          const WebLookupException(
            WebFailureKind.timeout,
            'The answer did not finish in time.',
            stage: WebLookupStage.extraction,
          ),
        );
      });
    }
    return completer.future;
  }
}

/// Maps an HTTP status code from a paid API onto a sanitized failure.
WebLookupException apiStatusException(int statusCode, WebLookupStage stage) {
  if (statusCode == 401 || statusCode == 403) {
    return WebLookupException(
      WebFailureKind.invalidKey,
      'The key was rejected. Replace it in Settings.',
      stage: stage,
    );
  }
  if (statusCode == 402) {
    return WebLookupException(
      WebFailureKind.quota,
      'The account has no remaining balance.',
      stage: stage,
    );
  }
  if (statusCode == 429) {
    return WebLookupException(
      WebFailureKind.quota,
      'The service is rate limiting this key.',
      stage: stage,
    );
  }
  if (statusCode >= 500) {
    return WebLookupException(
      WebFailureKind.unavailable,
      'The service reported an internal error.',
      stage: stage,
    );
  }
  return WebLookupException(
    WebFailureKind.malformed,
    'The service answered with status $statusCode.',
    stage: stage,
  );
}

/// Decodes a JSON object, mapping any parse problem to a sanitized failure.
Map<String, Object?> decodeJsonObject(
  String body, {
  required WebLookupStage stage,
}) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.cast<String, Object?>();
  } on Object {
    // Fall through to the sanitized failure below.
  }
  throw WebLookupException(
    WebFailureKind.malformed,
    'The service answer was not readable JSON.',
    stage: stage,
  );
}
