import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';

/// Failure raised by the transport layer before any provider parsing happens.
class TransportException implements Exception {
  const TransportException(this.kind, this.message, {this.retryAfter});

  final LookupFailureKind kind;
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => 'TransportException(${kind.name}): $message';
}

class TransportResponse {
  const TransportResponse({
    required this.statusCode,
    required this.headers,
    required this.bytes,
    required this.uri,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bytes;
  final Uri uri;

  String? header(String name) => headers[name.toLowerCase()];

  String get body => utf8.decode(bytes, allowMalformed: true);
}

/// Bounded, injectable HTTP GET.
abstract interface class HttpTransport {
  Future<TransportResponse> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout,
    int maxBytes,
    bool followRedirects,
  });
}

/// Real transport with one overall deadline per request.
///
/// The deadline covers the connection, the response headers *and* the whole
/// body: a server that trickles bytes forever cannot keep the request alive.
/// The socket is force-closed on deadline or when the byte cap is exceeded, and
/// network errors during the body are normalised to [TransportException].
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({
    HttpClient Function()? clientFactory,
    bool allowInsecureTestUris = false,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _allowInsecureTestUris = allowInsecureTestUris;

  final HttpClient Function() _clientFactory;

  /// Test-only seam for local in-process HTTP servers. Production traffic still
  /// requires HTTPS.
  final bool _allowInsecureTestUris;

  static const Duration defaultTimeout = Duration(seconds: 10);
  static const int defaultMaxBytes = 2 * 1024 * 1024;

  @override
  Future<TransportResponse> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = defaultTimeout,
    int maxBytes = defaultMaxBytes,
    bool followRedirects = true,
  }) async {
    final schemeAllowed =
        uri.scheme == 'https' ||
        (_allowInsecureTestUris && uri.scheme == 'http');
    if (!schemeAllowed) {
      throw const TransportException(
        LookupFailureKind.unavailable,
        'Only https requests are allowed.',
      );
    }
    if (timeout <= Duration.zero) {
      throw TransportException(
        LookupFailureKind.timeout,
        'No answer within ${timeout.inMilliseconds}ms.',
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
      final request = await client.getUrl(uri).timeout(remaining());
      request.followRedirects = followRedirects;
      for (final entry in (headers ?? const <String, String>{}).entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close().timeout(remaining());
      final bytes = await _readBounded(
        response,
        maxBytes: maxBytes,
        remaining: remaining,
        abort: abort,
      );
      final headerMap = <String, String>{};
      response.headers.forEach((name, values) {
        headerMap[name.toLowerCase()] = values.join(', ');
      });
      return TransportResponse(
        statusCode: response.statusCode,
        headers: headerMap,
        bytes: bytes,
        uri: uri,
      );
    } on TimeoutException {
      abort();
      throw TransportException(
        LookupFailureKind.timeout,
        'No complete answer within ${timeout.inSeconds}s.',
      );
    } on HandshakeException catch (error) {
      abort();
      throw TransportException(LookupFailureKind.network, error.message);
    } on SocketException catch (error) {
      abort();
      throw TransportException(LookupFailureKind.network, error.message);
    } on HttpException catch (error) {
      abort();
      throw TransportException(LookupFailureKind.network, error.message);
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
            TransportException(
              LookupFailureKind.unavailable,
              'Response is larger than ${maxBytes ~/ 1024} KiB.',
            ),
          );
        }
      },
      onError: (Object error) {
        fail(TransportException(LookupFailureKind.network, '$error'));
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
        const TransportException(
          LookupFailureKind.timeout,
          'The response did not finish within the deadline.',
        ),
      );
    } else {
      timer = Timer(left, () {
        fail(
          const TransportException(
            LookupFailureKind.timeout,
            'The response did not finish within the deadline.',
          ),
        );
      });
    }
    return completer.future;
  }
}

/// Parses a `Retry-After` header value: either delta-seconds or an HTTP date
/// (`Sun, 06 Nov 1994 08:49:37 GMT` and the two obsolete formats).
Duration? parseRetryAfter(String? value, {Clock? clock, DateTime? now}) {
  if (value == null || value.trim().isEmpty) return null;
  final trimmed = value.trim();
  final seconds = int.tryParse(trimmed);
  final reference = now ?? (clock ?? const SystemClock()).nowUtc();
  if (seconds != null) {
    return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
  }
  try {
    final date = HttpDate.parse(trimmed).toUtc();
    final difference = date.difference(reference.toUtc());
    return difference.isNegative ? Duration.zero : difference;
  } on Object {
    // HttpDate.parse throws HttpException for anything it cannot read.
    return null;
  }
}

/// Turns an absolute epoch-seconds reset header into a bounded delay.
///
/// A stale (past) timestamp yields zero, and an implausible far-future timestamp
/// is clamped so a bad header can never park a provider for years.
Duration resetDelayFromEpoch(
  String? value, {
  Clock? clock,
  Duration maxDelay = const Duration(hours: 1),
}) {
  if (value == null || value.trim().isEmpty) return Duration.zero;
  final epochSeconds = int.tryParse(value.trim());
  if (epochSeconds == null) return Duration.zero;
  final reference = (clock ?? const SystemClock()).nowUtc();
  final reset = DateTime.fromMillisecondsSinceEpoch(
    epochSeconds * 1000,
    isUtc: true,
  );
  final difference = reset.difference(reference);
  if (difference.isNegative) return Duration.zero;
  return difference > maxDelay ? maxDelay : difference;
}
