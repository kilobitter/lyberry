import 'package:lyberry/domain/lookup.dart';

/// Stage of the web lookup pipeline a failure belongs to.
enum WebLookupStage {
  search('Web search'),
  fetch('Page fetch'),
  extraction('Extraction'),
  keys('API keys');

  const WebLookupStage(this.label);

  final String label;
}

/// Sanitized failure classes for the paid web path. Messages never carry keys,
/// request headers or response bodies.
enum WebFailureKind {
  missingKey('Needs a key'),
  invalidKey('Key rejected'),
  quota('Quota or balance'),
  blocked('Page blocked'),
  noContent('Nothing readable'),
  malformed('Unexpected response'),
  timeout('Timed out'),
  network('Network unavailable'),
  cancelled('Cancelled'),
  unavailable('Unavailable');

  const WebFailureKind(this.label);

  final String label;
}

/// A failure raised by one web stage. The pipeline keeps going with the pages
/// and candidates it already has, so a partial result is still useful.
class WebLookupFailure {
  const WebLookupFailure({
    required this.stage,
    required this.label,
    required this.kind,
    required this.message,
  });

  final WebLookupStage stage;

  /// Human-readable source name, for example `Tavily` or a page host.
  final String label;
  final WebFailureKind kind;
  final String message;
}

/// Exception thrown inside a web client; the service converts it into a
/// [WebLookupFailure] so other stages can still answer.
class WebLookupException implements Exception {
  const WebLookupException(
    this.kind,
    this.message, {
    this.stage = WebLookupStage.fetch,
  });

  final WebFailureKind kind;
  final String message;
  final WebLookupStage stage;

  @override
  String toString() => 'WebLookupException(${kind.name}): $message';
}

/// Where a web candidate's fields came from.
enum WebCandidateOrigin {
  /// JSON-LD `Product` data with a matching GTIN on the same node.
  structured('Structured data', 'web_structured'),

  /// Extractive DeepSeek result, quoted from supplied page evidence.
  ai('AI extracted', 'web_deepseek');

  const WebCandidateOrigin(this.label, this.providerId);

  final String label;
  final String providerId;
}

/// One web candidate, always offered for review and never saved automatically.
class WebCandidate {
  const WebCandidate({
    required this.candidate,
    required this.origin,
    required this.sourceUrl,
  });

  final MetadataCandidate candidate;
  final WebCandidateOrigin origin;

  /// Public page the values came from; empty when no usable source was mapped.
  final String sourceUrl;

  /// Host shown next to the result, without the `www.` noise.
  String get domain {
    final host = Uri.tryParse(sourceUrl)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// Structured data carrying its own matching GTIN is an exact code match.
  bool get isExact => candidate.matchKind == MatchKind.exact;
}

/// One page whose text was actually retrieved (direct fetch or Tavily).
class WebSourcePage {
  const WebSourcePage({
    required this.id,
    required this.url,
    required this.title,
    required this.text,
    this.fromExtract = false,
  });

  /// Stable evidence id (`s1`..`s3`) assigned in code, never by a model.
  final String id;
  final String url;
  final String title;

  /// Visible page text, already bounded by the caller.
  final String text;

  /// True when Tavily Extract supplied this page instead of a direct fetch.
  final bool fromExtract;

  bool get hasText => text.trim().isNotEmpty;

  String get domain {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }
}

/// Everything one explicit web lookup produced.
class WebLookupOutcome {
  WebLookupOutcome({
    List<WebCandidate> candidates = const <WebCandidate>[],
    List<WebLookupFailure> failures = const <WebLookupFailure>[],
    List<WebSourcePage> pages = const <WebSourcePage>[],
    this.usedExtraction = false,
  }) : candidates = List<WebCandidate>.unmodifiable(candidates),
       failures = List<WebLookupFailure>.unmodifiable(failures),
       pages = List<WebSourcePage>.unmodifiable(pages);

  final List<WebCandidate> candidates;
  final List<WebLookupFailure> failures;
  final List<WebSourcePage> pages;

  /// True when at least one page went to the extraction model.
  final bool usedExtraction;

  bool get hasCandidates => candidates.isNotEmpty;

  /// Every retrieval attempt failed: the UI can offer the alternate path.
  bool get allRetrievalFailed => candidates.isEmpty && pages.isEmpty;
}
