import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/api_transport.dart';
import 'package:lyberry/services/web/address_policy.dart';

/// One search hit, with whatever page content Tavily returned for it.
class TavilyHit {
  const TavilyHit({
    required this.url,
    required this.title,
    this.snippet = '',
    this.rawContent,
  });

  final String url;
  final String title;

  /// Tavily's short result snippet. It is never treated as page evidence.
  final String snippet;

  /// Retrieved page content, when the search asked for it.
  final String? rawContent;

  Uri? get uri {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return null;
    if (!AddressPolicy.isAllowedPageUri(parsed)) return null;
    return parsed;
  }
}

/// Explicit Tavily Search/Extract client. One call per user action.
class TavilyClient {
  TavilyClient({
    required ApiTransport transport,
    required String apiKey,
    this.timeout = IoApiTransport.callTimeout,
    this.maxResults = 3,
    this.maxRawContentPerHit = 512 * 1024,
  }) : _transport = transport,
       _apiKey = apiKey;

  static final Uri searchEndpoint = Uri.parse('https://api.tavily.com/search');
  static final Uri extractEndpoint = Uri.parse(
    'https://api.tavily.com/extract',
  );

  final ApiTransport _transport;
  final String _apiKey;
  final Duration timeout;
  final int maxResults;
  final int maxRawContentPerHit;

  /// Search for the quoted canonical code plus the optional medium hint.
  ///
  /// [timeout] is the caller's remaining budget, already clamped to the API cap.
  Future<List<TavilyHit>> search({
    required String query,
    Duration? timeout,
  }) async {
    final response = await _transport.post(
      ApiRequest(
        uri: searchEndpoint,
        bearerToken: _apiKey,
        body: <String, Object?>{
          'query': query,
          'exact_match': true,
          'search_depth': 'basic',
          'auto_parameters': false,
          'max_results': maxResults,
          'include_answer': false,
          'include_raw_content': 'text',
          'include_images': false,
        },
      ),
      timeout: timeout ?? this.timeout,
      maxBytes: IoApiTransport.tavilyMaxBytes,
    );
    if (response.statusCode != 200) {
      throw apiStatusException(response.statusCode, WebLookupStage.search);
    }
    final decoded = decodeJsonObject(
      response.body,
      stage: WebLookupStage.search,
    );
    final results = decoded['results'];
    if (results is! List) {
      throw const WebLookupException(
        WebFailureKind.malformed,
        'The search answer had no result list.',
        stage: WebLookupStage.search,
      );
    }
    final hits = <TavilyHit>[];
    for (final entry in results) {
      if (hits.length >= maxResults) break;
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      final url = _string(map['url']);
      if (url == null) continue;
      final hit = TavilyHit(
        url: url,
        title: _string(map['title']) ?? '',
        snippet: _string(map['content']) ?? '',
        rawContent: _clipRaw(_string(map['raw_content'])),
      );
      // Only public HTTPS pages become sources; anything else is dropped
      // rather than validated later.
      if (hit.uri == null) continue;
      hits.add(hit);
    }
    return hits;
  }

  /// Extract page text for the URLs a direct fetch could not read.
  ///
  /// The response is matched back to the requested URLs: an unrelated answer
  /// can never inject a new source.
  Future<Map<String, String>> extract(
    List<Uri> urls, {
    Duration? timeout,
  }) async {
    if (urls.isEmpty) return const <String, String>{};
    final requested = <String, Uri>{
      for (final uri in urls) uri.toString(): uri,
    };
    final response = await _transport.post(
      ApiRequest(
        uri: extractEndpoint,
        bearerToken: _apiKey,
        body: <String, Object?>{
          'urls': requested.keys.toList(growable: false),
          'extract_depth': 'basic',
          'format': 'text',
          'include_images': false,
          // The API's own per-request budget, as contracted.
          'timeout': 10,
        },
      ),
      timeout: timeout ?? this.timeout,
      maxBytes: IoApiTransport.tavilyMaxBytes,
    );
    if (response.statusCode != 200) {
      throw apiStatusException(response.statusCode, WebLookupStage.fetch);
    }
    final decoded = decodeJsonObject(
      response.body,
      stage: WebLookupStage.fetch,
    );
    final results = decoded['results'];
    if (results is! List) {
      throw const WebLookupException(
        WebFailureKind.malformed,
        'The extract answer had no result list.',
        stage: WebLookupStage.fetch,
      );
    }
    final extracted = <String, String>{};
    for (final entry in results) {
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      final url = _string(map['url']);
      if (url == null) continue;
      final known = requested[url];
      if (known == null) continue;
      final content = _string(map['raw_content']) ?? _string(map['content']);
      if (content == null || content.trim().isEmpty) continue;
      extracted[known.toString()] = content;
    }
    return extracted;
  }

  String? _clipRaw(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length <= maxRawContentPerHit
        ? trimmed
        : trimmed.substring(0, maxRawContentPerHit);
  }

  static String? _string(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }
}
