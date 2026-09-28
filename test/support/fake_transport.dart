import 'dart:convert';
import 'dart:typed_data';

import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/transport.dart';

/// Deterministic HTTP transport for provider and cover tests.
class FakeHttpTransport implements HttpTransport {
  FakeHttpTransport({
    Map<String, String>? bodies,
    Map<String, int>? statuses,
    Map<String, Map<String, String>>? headers,
    Map<String, Uint8List>? bytes,
    Map<String, Duration>? delays,
    this.failure,
  }) : _bodies = bodies ?? <String, String>{},
       _statuses = statuses ?? <String, int>{},
       _headers = headers ?? <String, Map<String, String>>{},
       _bytes = bytes ?? <String, Uint8List>{},
       _delays = delays ?? <String, Duration>{};

  final Map<String, String> _bodies;
  final Map<String, int> _statuses;
  final Map<String, Map<String, String>> _headers;
  final Map<String, Uint8List> _bytes;
  final Map<String, Duration> _delays;

  /// When set, every request throws this instead of answering.
  TransportException? failure;

  final List<Uri> requests = <Uri>[];

  void answer(
    String url, {
    required String body,
    int status = 200,
    Map<String, String>? headers,
    Duration? delay,
  }) {
    _bodies[url] = body;
    _statuses[url] = status;
    if (headers != null) _headers[url] = headers;
    if (delay != null) _delays[url] = delay;
  }

  void answerBytes(
    String url,
    Uint8List bytes, {
    int status = 200,
    Duration? delay,
  }) {
    _bytes[url] = bytes;
    _statuses[url] = status;
    if (delay != null) _delays[url] = delay;
  }

  @override
  Future<TransportResponse> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = IoHttpTransport.defaultTimeout,
    int maxBytes = IoHttpTransport.defaultMaxBytes,
    bool followRedirects = true,
  }) async {
    requests.add(uri);
    final problem = failure;
    if (problem != null) throw problem;

    final key = uri.toString();
    final delay = _delays[key];
    if (delay != null && delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final status = _statuses[key] ?? 404;
    final bytes =
        _bytes[key] ?? Uint8List.fromList(utf8.encode(_bodies[key] ?? ''));
    if (bytes.length > maxBytes) {
      throw const TransportException(
        LookupFailureKind.unavailable,
        'Response is larger than the byte limit.',
      );
    }
    return TransportResponse(
      statusCode: status,
      headers: <String, String>{
        for (final entry in (_headers[key] ?? const <String, String>{}).entries)
          entry.key.toLowerCase(): entry.value,
      },
      bytes: bytes,
      uri: uri,
    );
  }
}
