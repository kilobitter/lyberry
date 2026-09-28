import 'dart:convert';

import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/api_transport.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/web/address_policy.dart';
import 'package:lyberry/services/web/code_matching.dart';
import 'package:lyberry/services/web/deepseek_client.dart';
import 'package:lyberry/services/web/page_fetcher.dart';
import 'package:lyberry/services/web/product_extractor.dart';
import 'package:lyberry/services/web/tavily_client.dart';

/// Explicit, user-triggered web lookup: Tavily search (or an imported link),
/// safe page fetch, structured product data first, DeepSeek only when the page
/// has no matching structured record.
///
/// Every call corresponds to one user action and is guarded by a single-flight
/// lock that is only released when the whole pipeline (including extraction) has
/// finished. Cancellation and the wall-clock budget are tracked as one
/// immutable per-operation identity, so a cancelled operation can never be
/// reactivated by a later tap, and no stage starts once either has fired.
class WebLookupService {
  WebLookupService({
    required ApiKeyStore keys,
    required ApiTransport transport,
    required PageFetcher pages,
    this.budget = const Duration(seconds: 90),
    this.pageTimeout = const Duration(seconds: 10),
    this.maxPages = 3,
    this.evidenceCharsPerSource = 12 * 1024,
    this.evidenceCharsTotal = 36 * 1024,
  }) : _keys = keys,
       _transport = transport,
       _pages = pages;

  /// Whole-request cap for one Tavily call.
  static const Duration tavilyRequestCap = Duration(seconds: 30);

  /// Whole-request cap for one DeepSeek call.
  static const Duration deepSeekRequestCap = Duration(seconds: 30);

  final ApiKeyStore _keys;
  final ApiTransport _transport;
  final PageFetcher _pages;

  final Duration budget;
  final Duration pageTimeout;
  final int maxPages;
  final int evidenceCharsPerSource;
  final int evidenceCharsTotal;

  bool _inFlight = false;

  Future<bool> hasKey(WebKeyProvider provider) => _keys.has(provider);

  /// Search the web for one identifier. Requires the Tavily key.
  Future<WebLookupOutcome> search(
    LookupQuery query, {
    bool Function()? isCancelled,
  }) {
    return _singleFlight(
      isCancelled: isCancelled,
      body: (pipeline) => _search(query, pipeline),
    );
  }

  /// Read one pasted public HTTPS product link. Structured data needs no key.
  Future<WebLookupOutcome> importLink({
    required NormalizedIdentifier identifier,
    required Uri url,
    MediaType? mediumHint,
    bool Function()? isCancelled,
  }) {
    return _singleFlight(
      isCancelled: isCancelled,
      body: (pipeline) => _importLink(
        identifier: identifier,
        url: url,
        mediumHint: mediumHint,
        pipeline: pipeline,
      ),
    );
  }

  /// Search text sent to Tavily: the quoted canonical code plus a medium hint.
  static String searchQuery(LookupQuery query) {
    final buffer = StringBuffer('"${query.identifier.canonicalKey}"');
    final hint = query.mediumHint;
    if (hint != null) buffer.write(' ${hint.label}');
    return buffer.toString();
  }

  void close() => _pages.close();

  /// Runs [body] under the single-flight lock, releasing it only after the
  /// whole pipeline completes.
  Future<WebLookupOutcome> _singleFlight({
    required Future<WebLookupOutcome> Function(_Pipeline pipeline) body,
    bool Function()? isCancelled,
  }) async {
    if (_inFlight) return _busyOutcome();
    _inFlight = true;
    final pipeline = _Pipeline(
      deadline: DateTime.now().add(budget),
      isCancelled: isCancelled,
    );
    try {
      return await body(pipeline);
    } finally {
      _inFlight = false;
    }
  }

  Future<WebLookupOutcome> _search(
    LookupQuery query,
    _Pipeline pipeline,
  ) async {
    final failures = <WebLookupFailure>[];
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[pipeline.stopFailure],
      );
    }

    final tavilyKey = await _readKey(WebKeyProvider.tavily, failures);
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[pipeline.stopFailure],
      );
    }
    if (tavilyKey == null) return WebLookupOutcome(failures: failures);

    final client = TavilyClient(transport: _transport, apiKey: tavilyKey);
    final List<TavilyHit> hits;
    try {
      hits = await client.search(
        query: searchQuery(query),
        timeout: pipeline.stageTimeout(tavilyRequestCap),
      );
    } on WebLookupException catch (error) {
      failures.add(_failure('Tavily', error));
      return WebLookupOutcome(failures: failures);
    }
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[...failures, pipeline.stopFailure],
      );
    }
    if (hits.isEmpty) {
      failures.add(
        WebLookupFailure(
          stage: WebLookupStage.search,
          label: 'Tavily',
          kind: WebFailureKind.noContent,
          message:
              'No public page mentioned ${query.identifier.canonicalKey}. You '
              'can paste a product link instead.',
        ),
      );
      return WebLookupOutcome(failures: failures);
    }

    return _finish(
      identifier: query.identifier,
      mediumHint: query.mediumHint,
      retrieved: await _retrieve(
        hits: hits,
        tavilyKey: tavilyKey,
        pipeline: pipeline,
        failures: failures,
        identifier: query.identifier,
      ),
      failures: failures,
      tavilyKey: tavilyKey,
      pipeline: pipeline,
    );
  }

  Future<WebLookupOutcome> _importLink({
    required NormalizedIdentifier identifier,
    required Uri url,
    required MediaType? mediumHint,
    required _Pipeline pipeline,
  }) async {
    final failures = <WebLookupFailure>[];
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[pipeline.stopFailure],
      );
    }
    if (!AddressPolicy.isAllowedPageUri(url)) {
      failures.add(
        const WebLookupFailure(
          stage: WebLookupStage.fetch,
          label: 'Link',
          kind: WebFailureKind.blocked,
          message:
              'Only public https product links can be read. Private or '
              'non-https links are refused.',
        ),
      );
      return WebLookupOutcome(failures: failures);
    }

    final tavilyKey = await _readKey(
      WebKeyProvider.tavily,
      failures,
      soft: true,
    );
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[pipeline.stopFailure],
      );
    }

    final retrieved = <_RetrievedPage>[];
    try {
      final page = await _pages.fetch(
        url,
        timeout: pipeline.stageTimeout(pageTimeout),
        isCancelled: () => pipeline.stopped,
      );
      retrieved.addAll(
        _pageFromResponse(
          page,
          hint: url.host,
          fromExtract: false,
          identifier: identifier,
        ),
      );
    } on WebLookupException catch (error) {
      if (pipeline.stopped) {
        return WebLookupOutcome(
          failures: <WebLookupFailure>[pipeline.stopFailure],
        );
      }
      if (tavilyKey != null) {
        await _extractFallback(
          urls: <Uri>[url],
          tavilyKey: tavilyKey,
          retrieved: retrieved,
          failures: failures,
          matchesCode: (digits) => identifier.matches(digits),
          pipeline: pipeline,
        );
      } else {
        failures.add(_failure(url.host, error));
        failures.add(_needsTavilyForFallback(url.host));
      }
    }
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[pipeline.stopFailure],
      );
    }

    return _finish(
      identifier: identifier,
      mediumHint: mediumHint,
      retrieved: retrieved,
      failures: failures,
      tavilyKey: tavilyKey,
      pipeline: pipeline,
    );
  }

  Future<WebLookupOutcome> _finish({
    required NormalizedIdentifier identifier,
    required MediaType? mediumHint,
    required List<_RetrievedPage> retrieved,
    required List<WebLookupFailure> failures,
    required String? tavilyKey,
    required _Pipeline pipeline,
  }) async {
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[...failures, pipeline.stopFailure],
      );
    }
    if (retrieved.isEmpty) {
      if (failures.isEmpty) {
        failures.add(
          WebLookupFailure(
            stage: WebLookupStage.fetch,
            label: 'Page fetch',
            kind: WebFailureKind.noContent,
            message:
                'No page could be read for ${identifier.value}. You can add the '
                'copy by hand or try another link.',
          ),
        );
      }
      return WebLookupOutcome(failures: failures);
    }

    final pages = <WebSourcePage>[
      for (var index = 0; index < retrieved.length; index++)
        retrieved[index].page(id: 's${index + 1}'),
    ];

    // Structured data first: a Product node carrying the code is exact and
    // never needs a model call.
    final structured = <WebCandidate>[];
    for (var index = 0; index < retrieved.length; index++) {
      final page = pages[index];
      for (final product in retrieved[index].products) {
        structured.add(
          WebCandidate(
            candidate: MetadataCandidate(
              providerId: WebCandidateOrigin.structured.providerId,
              providerLabel: WebCandidateOrigin.structured.label,
              externalId: '${page.url}#${identifier.canonicalKey}',
              matchKind: MatchKind.exact,
              title: product.title,
              medium: product.medium ?? mediumHint,
              creator: product.creator,
              year: product.year,
              publisher: product.publisher,
              description: product.description,
              platform: product.platform,
              coverUrl: product.coverUrl,
              sourceUrl: page.url,
            ),
            origin: WebCandidateOrigin.structured,
            sourceUrl: page.url,
          ),
        );
      }
    }
    if (structured.isNotEmpty) {
      return WebLookupOutcome(
        candidates: structured,
        failures: failures,
        pages: pages,
      );
    }

    // Evidence gate: a model never sees a page that does not carry the code.
    final evidence = <WebSourcePage>[
      for (final page in pages)
        if (_evidenceFor(page, identifier) case final excerpt?)
          WebSourcePage(
            id: page.id,
            url: page.url,
            title: page.title,
            text: excerpt,
            fromExtract: page.fromExtract,
          ),
    ];
    if (evidence.isEmpty) {
      failures.add(
        WebLookupFailure(
          stage: WebLookupStage.extraction,
          label: 'Page evidence',
          kind: WebFailureKind.noContent,
          message:
              'The retrieved pages did not show ${identifier.value} as a whole '
              'code, so nothing was sent for extraction. The product may be '
              'listed under another code; you can paste its link instead.',
        ),
      );
      return WebLookupOutcome(failures: failures, pages: pages);
    }

    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[...failures, pipeline.stopFailure],
        pages: pages,
      );
    }

    final deepSeekKey = await _readKey(WebKeyProvider.deepseek, failures);
    if (pipeline.stopped) {
      return WebLookupOutcome(
        failures: <WebLookupFailure>[...failures, pipeline.stopFailure],
        pages: pages,
      );
    }
    if (deepSeekKey == null) {
      return WebLookupOutcome(failures: failures, pages: pages);
    }

    try {
      final client = DeepSeekClient(transport: _transport, apiKey: deepSeekKey);
      final extracted = await client.extract(
        requestedCode: identifier.value,
        equivalentCodes: identifier.equivalents.toList(growable: false),
        pages: evidence,
        timeout: pipeline.stageTimeout(deepSeekRequestCap),
      );
      if (pipeline.stopped) {
        return WebLookupOutcome(
          failures: <WebLookupFailure>[...failures, pipeline.stopFailure],
          pages: pages,
          usedExtraction: true,
        );
      }
      if (extracted.isEmpty) {
        failures.add(
          WebLookupFailure(
            stage: WebLookupStage.extraction,
            label: 'DeepSeek',
            kind: WebFailureKind.noContent,
            message:
                'The pages did not establish a product for ${identifier.value}. '
                'Add the copy by hand, or paste the product link.',
          ),
        );
        return WebLookupOutcome(
          failures: failures,
          pages: pages,
          usedExtraction: true,
        );
      }
      final byId = <String, WebSourcePage>{
        for (final page in evidence) page.id: page,
      };
      final candidates = <WebCandidate>[];
      for (final candidate in extracted) {
        final source = byId[candidate.sourceId];
        if (source == null) continue;
        candidates.add(
          WebCandidate(
            candidate: MetadataCandidate(
              providerId: WebCandidateOrigin.ai.providerId,
              providerLabel: WebCandidateOrigin.ai.label,
              externalId: '${source.url}#${identifier.canonicalKey}',
              matchKind: MatchKind.possible,
              title: candidate.title,
              medium: candidate.medium ?? mediumHint,
              creator: candidate.creator ?? '',
              year: candidate.year,
              publisher: candidate.publisher ?? '',
              description: candidate.description ?? '',
              platform: candidate.platform ?? '',
              sourceUrl: source.url,
            ),
            origin: WebCandidateOrigin.ai,
            sourceUrl: source.url,
          ),
        );
      }
      return WebLookupOutcome(
        candidates: candidates,
        failures: failures,
        pages: pages,
        usedExtraction: true,
      );
    } on WebLookupException catch (error) {
      failures.add(_failure('DeepSeek', error));
      return WebLookupOutcome(
        failures: failures,
        pages: pages,
        usedExtraction: true,
      );
    }
  }

  Future<List<_RetrievedPage>> _retrieve({
    required List<TavilyHit> hits,
    required String tavilyKey,
    required _Pipeline pipeline,
    required List<WebLookupFailure> failures,
    required NormalizedIdentifier identifier,
  }) async {
    final unique = <String, TavilyHit>{};
    for (final hit in hits) {
      final uri = hit.uri;
      if (uri == null) continue;
      unique.putIfAbsent(uri.toString(), () => hit);
      if (unique.length >= maxPages) break;
    }

    final retrieved = <_RetrievedPage>[];
    final failed = <Uri>[];
    await Future.wait(
      unique.values.map((hit) async {
        if (pipeline.stopped) return;
        final uri = hit.uri!;
        try {
          final page = await _pages.fetch(
            uri,
            timeout: pipeline.stageTimeout(pageTimeout),
            isCancelled: () => pipeline.stopped,
          );
          retrieved.addAll(
            _pageFromResponse(
              page,
              hint: hit.title,
              fromExtract: false,
              identifier: identifier,
            ),
          );
          return;
        } on WebLookupException catch (error) {
          if (pipeline.stopped) return;
          final raw = hit.rawContent;
          // The direct read failed even though the page may still be usable
          // through Tavily's retrieved content, so say so in the log.
          failures.add(_failure(uri.host, error));
          if (raw != null && raw.trim().isNotEmpty) {
            // Search already retrieved this content; it is page evidence even
            // when our own fetch was refused.
            retrieved.add(
              _RetrievedPage.raw(
                uri,
                hit.title,
                raw,
                false,
                matchesCode: (digits) => identifier.matches(digits),
              ),
            );
            return;
          }
          failed.add(uri);
        }
      }),
    );

    if (failed.isNotEmpty && !pipeline.stopped) {
      await _extractFallback(
        urls: failed,
        tavilyKey: tavilyKey,
        retrieved: retrieved,
        failures: failures,
        matchesCode: (digits) => identifier.matches(digits),
        pipeline: pipeline,
      );
    }
    return retrieved;
  }

  Future<void> _extractFallback({
    required List<Uri> urls,
    required String tavilyKey,
    required List<_RetrievedPage> retrieved,
    required List<WebLookupFailure> failures,
    required bool Function(String digits) matchesCode,
    required _Pipeline pipeline,
  }) async {
    if (urls.isEmpty || pipeline.stopped) return;
    try {
      final client = TavilyClient(transport: _transport, apiKey: tavilyKey);
      final extracted = await client.extract(
        urls,
        timeout: pipeline.stageTimeout(tavilyRequestCap),
      );
      if (pipeline.stopped) return;
      for (final uri in urls) {
        final text = extracted[uri.toString()];
        if (text == null || text.trim().isEmpty) continue;
        retrieved.add(
          _RetrievedPage.raw(
            uri,
            uri.host,
            text,
            true,
            matchesCode: matchesCode,
          ),
        );
      }
      if (retrieved.isEmpty) {
        failures.add(
          WebLookupFailure(
            stage: WebLookupStage.fetch,
            label: 'Tavily Extract',
            kind: WebFailureKind.noContent,
            message: 'The pages could not be read and Tavily returned no text.',
          ),
        );
      }
    } on WebLookupException catch (error) {
      failures.add(_failure('Tavily Extract', error));
    }
  }

  List<_RetrievedPage> _pageFromResponse(
    FetchedPage page, {
    required String hint,
    required bool fromExtract,
    required NormalizedIdentifier identifier,
  }) {
    if (!page.isSuccess) {
      throw WebLookupException(
        page.statusCode == 403 || page.statusCode == 401
            ? WebFailureKind.blocked
            : WebFailureKind.network,
        page.statusCode == 403 || page.statusCode == 401
            ? 'That page refused to be read.'
            : 'That page answered with status ${page.statusCode}.',
      );
    }
    if (!page.isTextual) {
      throw const WebLookupException(
        WebFailureKind.noContent,
        'That page was not text or HTML.',
      );
    }
    final body = page.text;
    final title = _titleOf(body) ?? hint;
    return <_RetrievedPage>[
      _RetrievedPage.html(
        page.uri,
        title,
        body,
        fromExtract,
        matchesCode: (digits) => identifier.matches(digits),
      ),
    ];
  }

  Future<String?> _readKey(
    WebKeyProvider provider,
    List<WebLookupFailure> failures, {
    bool soft = false,
  }) async {
    try {
      final value = await _keys.read(provider);
      if (value != null) return value;
      if (!soft) {
        failures.add(
          WebLookupFailure(
            stage: provider == WebKeyProvider.tavily
                ? WebLookupStage.search
                : WebLookupStage.extraction,
            label: provider.label,
            kind: WebFailureKind.missingKey,
            message:
                'Add a ${provider.label} key in Settings to use this step.',
          ),
        );
      }
      return null;
    } on WebLookupException catch (error) {
      failures.add(_failure(provider.label, error));
      return null;
    }
  }

  WebLookupFailure _failure(String label, WebLookupException error) =>
      WebLookupFailure(
        stage: error.stage,
        label: label,
        kind: error.kind,
        message: error.message,
      );

  WebLookupFailure _needsTavilyForFallback(String host) => WebLookupFailure(
    stage: WebLookupStage.fetch,
    label: host,
    kind: WebFailureKind.blocked,
    message:
        'This page refused a direct read. Add a Tavily key in Settings to try '
        'Tavily Extract, or paste another link.',
  );

  WebLookupOutcome _busyOutcome() => WebLookupOutcome(
    failures: const <WebLookupFailure>[
      WebLookupFailure(
        stage: WebLookupStage.search,
        label: 'Web lookup',
        kind: WebFailureKind.cancelled,
        message: 'A web lookup is already running.',
      ),
    ],
  );

  /// Bounded evidence window around the matching code, or null when the page
  /// never shows the code as a whole identifier (separators are tolerated).
  ///
  /// The excerpt is measured in UTF-8 bytes so the model never receives more
  /// than the contracted budget, and the same bytes are what validation checks.
  String? _evidenceFor(WebSourcePage page, NormalizedIdentifier identifier) {
    final text = page.text;
    if (text.trim().isEmpty) return null;
    final indexes = CodeMatching.occurrences(text, identifier.equivalents);
    if (indexes.isEmpty) return null;

    final buffer = StringBuffer();
    var bytes = 0;
    var lastEnd = -1;
    for (final index in indexes) {
      final start = index - 1500 < 0 ? 0 : index - 1500;
      final end = index + 1500 > text.length ? text.length : index + 1500;
      if (start < lastEnd) continue;
      lastEnd = end;
      final excerpt = text.substring(start, end).trim();
      if (excerpt.isEmpty) continue;
      final separator = buffer.isEmpty ? '' : '\n...\n';
      final separatorBytes = utf8.encode(separator).length;
      final remaining = evidenceCharsPerSource - bytes - separatorBytes;
      if (remaining <= 0) break;
      final bounded = _clipUtf8(excerpt, remaining);
      if (bounded.isEmpty) break;
      buffer.write(separator);
      buffer.write(bounded);
      bytes += separatorBytes + utf8.encode(bounded).length;
      if (bytes >= evidenceCharsPerSource) break;
    }
    if (buffer.isEmpty) return null;
    final excerpt = buffer.toString();
    return utf8.encode(excerpt).length <= evidenceCharsTotal
        ? excerpt
        : _clipUtf8(excerpt, evidenceCharsTotal);
  }

  /// Longest prefix of [value] that fits in [maxBytes] UTF-8 bytes.
  static String _clipUtf8(String value, int maxBytes) {
    if (maxBytes <= 0) return '';
    if (utf8.encode(value).length <= maxBytes) return value;
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (bytes + size > maxBytes) break;
      buffer.write(char);
      bytes += size;
    }
    return buffer.toString();
  }

  static String? _titleOf(String html) {
    final match = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (match == null) return null;
    final title = match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.isEmpty) return null;
    return title.length <= 300 ? title : title.substring(0, 300);
  }
}

/// Immutable cancellation + deadline identity for exactly one operation.
///
/// A later tap cannot revive it: the external cancellation callback and the
/// deadline are captured once and never reset.
class _Pipeline {
  _Pipeline({required DateTime deadline, bool Function()? isCancelled})
    : _deadline = deadline,
      _isCancelled = isCancelled;

  final DateTime _deadline;
  final bool Function()? _isCancelled;

  bool get cancelled => _isCancelled?.call() ?? false;

  Duration get remaining {
    final left = _deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get stopped => cancelled || remaining <= Duration.zero;

  /// The longest this stage may take: its own cap, or what is left.
  Duration stageTimeout(Duration cap) {
    final left = remaining;
    if (left <= Duration.zero) return Duration.zero;
    return left < cap ? left : cap;
  }

  /// Distinguishes a user stop from an exhausted budget.
  WebLookupFailure get stopFailure => cancelled
      ? const WebLookupFailure(
          stage: WebLookupStage.search,
          label: 'Web lookup',
          kind: WebFailureKind.cancelled,
          message: 'Stopped. Nothing was saved.',
        )
      : const WebLookupFailure(
          stage: WebLookupStage.search,
          label: 'Web lookup',
          kind: WebFailureKind.timeout,
          message: 'The web lookup ran out of time. Nothing was saved.',
        );
}

/// One retrieved page plus any structured products found on it.
class _RetrievedPage {
  const _RetrievedPage({
    required this.uri,
    required this.title,
    required this.text,
    required this.products,
    required this.fromExtract,
  });

  factory _RetrievedPage.html(
    Uri uri,
    String title,
    String html,
    bool fromExtract, {
    required bool Function(String digits) matchesCode,
  }) {
    final extraction = ProductExtractor.extract(html, matchesCode: matchesCode);
    return _RetrievedPage(
      uri: uri,
      title: title,
      text: extraction.visibleText,
      products: extraction.products,
      fromExtract: fromExtract,
    );
  }

  factory _RetrievedPage.raw(
    Uri uri,
    String title,
    String text,
    bool fromExtract, {
    required bool Function(String digits) matchesCode,
  }) {
    // Tavily content may still be HTML: the structured fast path applies there
    // too, so a blocked direct fetch can still produce an exact candidate.
    if (text.contains('application/ld+json')) {
      final extraction = ProductExtractor.extract(
        text,
        matchesCode: matchesCode,
      );
      return _RetrievedPage(
        uri: uri,
        title: title,
        text: extraction.visibleText.isEmpty ? text : extraction.visibleText,
        products: extraction.products,
        fromExtract: fromExtract,
      );
    }
    return _RetrievedPage(
      uri: uri,
      title: title,
      text: text,
      products: const <StructuredProduct>[],
      fromExtract: fromExtract,
    );
  }

  final Uri uri;
  final String title;
  final String text;
  final List<StructuredProduct> products;
  final bool fromExtract;

  WebSourcePage page({required String id}) => WebSourcePage(
    id: id,
    url: uri.toString(),
    title: title,
    text: text,
    fromExtract: fromExtract,
  );
}
