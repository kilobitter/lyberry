import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/api_transport.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/web/page_fetcher.dart';

/// In-memory key store. Only synthetic keys ever go in here.
class InMemoryApiKeyStore implements ApiKeyStore {
  InMemoryApiKeyStore({Map<CredentialKey, String>? initial})
    : _values = <CredentialKey, String>{...?initial};

  final Map<CredentialKey, String> _values;

  /// When set, every write throws this failure instead of storing.
  WebLookupException? writeFailure;

  /// When set, every remove throws this failure instead of deleting.
  WebLookupException? removeFailure;

  /// When set, every read throws this failure.
  WebLookupException? readFailure;

  /// Per-provider read failures, for tests that need one credential group to
  /// fail while another stays readable.
  final Map<CredentialKey, WebLookupException> readFailures =
      <CredentialKey, WebLookupException>{};

  /// Optional delay applied to reads, to test cancellation during a key read.
  Duration readDelay = Duration.zero;

  /// Per-provider read delays, for tests that need one group to be slow.
  final Map<CredentialKey, Duration> readDelays = <CredentialKey, Duration>{};

  int writes = 0;
  int removes = 0;
  int reads = 0;

  String? peek(CredentialKey provider) => _values[provider];

  @override
  Future<bool> has(CredentialKey provider) async =>
      (_values[provider] ?? '').isNotEmpty;

  @override
  Future<String?> read(CredentialKey provider) async {
    reads++;
    final delay = readDelays[provider] ?? readDelay;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final failure = readFailures[provider] ?? readFailure;
    if (failure != null) throw failure;
    return _values[provider];
  }

  @override
  Future<void> write(CredentialKey provider, String value) async {
    writes++;
    final failure = writeFailure;
    final problem = describeApiKeyProblem(value);
    // Real secure storage answers asynchronously; keep the same shape here so
    // callers always see a Future error instead of a synchronous throw.
    await Future<void>.delayed(Duration.zero);
    if (failure != null) throw failure;
    if (problem != null) {
      throw WebLookupException(
        WebFailureKind.missingKey,
        problem,
        stage: WebLookupStage.keys,
      );
    }
    _values[provider] = value.trim();
  }

  @override
  Future<void> remove(CredentialKey provider) async {
    removes++;
    final failure = removeFailure;
    await Future<void>.delayed(Duration.zero);
    if (failure != null) throw failure;
    _values.remove(provider);
  }
}

/// One scripted API answer.
class FakeApiCall {
  FakeApiCall({
    required this.statusCode,
    this.json,
    this.rawBody,
    this.delay = Duration.zero,
    this.error,
  });

  final int statusCode;
  final Map<String, Object?>? json;
  final String? rawBody;
  final Duration delay;
  final WebLookupException? error;
}

/// Records every API request and answers from a script, host by host.
class FakeApiTransport implements ApiTransport {
  final List<ApiRequest> requests = <ApiRequest>[];

  /// Answers keyed by request host; the last answer is reused when a host is
  /// called again.
  final Map<String, List<FakeApiCall>> script = <String, List<FakeApiCall>>{};

  int get calls => requests.length;

  void enqueue(String host, FakeApiCall call) {
    script.putIfAbsent(host, () => <FakeApiCall>[]).add(call);
  }

  ApiRequest requestAt(int index) => requests[index];

  @override
  Future<ApiResponse> post(
    ApiRequest request, {
    required Duration timeout,
    required int maxBytes,
  }) async {
    requests.add(request);
    final host = request.uri.host;
    final queue = script[host];
    if (queue == null || queue.isEmpty) {
      throw WebLookupException(
        WebFailureKind.network,
        'No scripted answer for $host.',
        stage: WebLookupStage.search,
      );
    }
    final call = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (call.delay > Duration.zero) {
      await Future<void>.delayed(call.delay);
    }
    final error = call.error;
    if (error != null) throw error;
    final bytes = call.json != null
        ? Uint8List.fromList(utf8.encode(jsonEncode(call.json)))
        : Uint8List.fromList(utf8.encode(call.rawBody ?? ''));
    return ApiResponse(statusCode: call.statusCode, bytes: bytes);
  }
}

/// Page fetcher double: scripted answers per URL, plus a call log.
class FakePageFetcher implements PageFetcher {
  final Map<String, Object> _byUrl = <String, Object>{};
  final List<Uri> fetched = <Uri>[];
  bool closed = false;

  /// Optional hook, for example to emulate a user cancelling mid-fetch.
  void Function(Uri uri)? onFetch;

  void page(
    String url, {
    String body = '<html><body>page</body></html>',
    int statusCode = 200,
    String contentType = 'text/html; charset=utf-8',
  }) {
    _byUrl[url] = FetchedPage(
      uri: Uri.parse(url),
      statusCode: statusCode,
      contentType: contentType,
      bytes: Uint8List.fromList(utf8.encode(body)),
    );
  }

  void failure(String url, WebLookupException error) {
    _byUrl[url] = error;
  }

  @override
  Future<FetchedPage> fetch(
    Uri uri, {
    required Duration timeout,
    int maxBytes = SafePageFetcher.defaultMaxBytes,
    bool Function()? isCancelled,
  }) async {
    fetched.add(uri);
    onFetch?.call(uri);
    final scripted = _byUrl[uri.toString()];
    if (scripted == null) {
      throw const WebLookupException(
        WebFailureKind.network,
        'The page could not be reached.',
      );
    }
    if (scripted is WebLookupException) throw scripted;
    return scripted as FetchedPage;
  }

  @override
  void close() => closed = true;
}

/// Builds a Tavily search answer with the given results.
FakeApiCall tavilySearch(List<Map<String, Object?>> results) =>
    FakeApiCall(statusCode: 200, json: <String, Object?>{'results': results});

/// Builds a Tavily result entry.
Map<String, Object?> tavilyResult({
  required String url,
  String title = 'A product',
  String snippet = '',
  String? rawContent,
}) => <String, Object?>{
  'url': url,
  'title': title,
  'content': snippet,
  'raw_content': ?rawContent,
};

/// Builds a DeepSeek chat-completion answer carrying [envelope] as JSON text.
///
/// [finishReason] defaults to `stop`; `length` or `content_filter` model a
/// truncated answer the client must refuse.
FakeApiCall deepSeekAnswer(
  Map<String, Object?> envelope, {
  String finishReason = 'stop',
}) => FakeApiCall(
  statusCode: 200,
  json: <String, Object?>{
    'choices': <Map<String, Object?>>[
      <String, Object?>{
        'finish_reason': finishReason,
        'message': <String, Object?>{'content': jsonEncode(envelope)},
      },
    ],
  },
);

/// Builds a DeepSeek answer whose content is [content] verbatim.
FakeApiCall deepSeekRaw(String content, {String finishReason = 'stop'}) =>
    FakeApiCall(
      statusCode: 200,
      json: <String, Object?>{
        'choices': <Map<String, Object?>>[
          <String, Object?>{
            'finish_reason': finishReason,
            'message': <String, Object?>{'content': content},
          },
        ],
      },
    );

/// A page whose JSON-LD Product carries [code].
String productHtml({
  required String title,
  required String code,
  String? description,
  String? brand,
  String? publisher,
  String? released,
  String? image,
  String extraBody = '',
}) {
  final product = <String, Object?>{
    '@context': 'https://schema.org',
    '@type': 'Product',
    'name': title,
    'gtin13': code,
    'description': ?description,
    if (brand != null)
      'brand': <String, Object?>{'@type': 'Brand', 'name': brand},
    if (publisher != null) 'publisher': <String, Object?>{'name': publisher},
    'releaseDate': ?released,
    'image': ?image,
  };
  return '<html><head><title>$title</title></head><body>'
      '<script type="application/ld+json">${jsonEncode(product)}</script>'
      '<h1>$title</h1>$extraBody'
      '</body></html>';
}
