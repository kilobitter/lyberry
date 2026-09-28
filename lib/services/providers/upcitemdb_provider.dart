import 'dart:convert';

import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/providers/json.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/transport.dart';
import 'package:lyberry/services/user_agent.dart';

/// Free, key-free UPCitemdb trial lookup: the general fallback for DVDs,
/// Blu-rays, games and anything else without a dedicated provider.
///
/// The trial endpoint allows one request per 10 seconds, so the limiter is
/// consulted before the request and reports a cooldown instead of blocking the
/// UI. `X-RateLimit-Reset` is an absolute Unix timestamp, not a delay.
class UpcItemDbProvider implements MetadataProvider {
  UpcItemDbProvider({
    required HttpTransport transport,
    this.timeout = const Duration(seconds: 10),
    String? userAgent,
    ProviderRateLimiter? limiter,
    Clock? clock,
  }) : _transport = transport,
       _userAgent = userAgent ?? lyberryUserAgent(),
       _limiter = limiter,
       _clock = clock ?? const SystemClock();

  final HttpTransport _transport;
  final Duration timeout;
  final String _userAgent;
  final ProviderRateLimiter? _limiter;
  final Clock _clock;

  @override
  String get id => 'upcitemdb';

  @override
  String get label => 'UPCitemdb';

  @override
  Set<ProviderRole> get roles => const <ProviderRole>{ProviderRole.general};

  @override
  bool supports(MediaType? mediumHint) => true;

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    final identifier = query.identifier;
    final uri = Uri.https(
      'api.upcitemdb.com',
      '/prod/trial/lookup',
      <String, String>{'upc': identifier.canonicalKey},
    );

    await _limiter?.guard();

    final TransportResponse response;
    try {
      response = await _transport.get(
        uri,
        headers: <String, String>{
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        },
        timeout: timeout,
      );
    } on TransportException catch (error) {
      throw ProviderException(
        error.kind,
        error.message,
        retryAfter: error.retryAfter,
      );
    }

    if (response.statusCode == 429) {
      throw ProviderException(
        LookupFailureKind.quota,
        'UPCitemdb free quota is exhausted for now.',
        retryAfter:
            parseRetryAfter(response.header('retry-after'), clock: _clock) ??
            _resetDelay(response) ??
            const Duration(seconds: 60),
      );
    }
    if (response.statusCode >= 400) {
      throw ProviderException(
        LookupFailureKind.http,
        'UPCitemdb answered ${response.statusCode}.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'UPCitemdb sent a response Lyberry could not read.',
      );
    }
    final root = jsonMap(decoded);
    if (root == null) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'UPCitemdb sent an unexpected response shape.',
      );
    }

    final code = jsonString(root['code']);
    if (code == 'TOO_FAST' || code == 'EXCEED_LIMIT') {
      final message = jsonString(root['message']).trim();
      throw ProviderException(
        LookupFailureKind.quota,
        message.isEmpty
            ? 'UPCitemdb free quota is exhausted for now.'
            : message,
        retryAfter:
            _resetDelay(response) ??
            parseRetryAfter(response.header('retry-after'), clock: _clock) ??
            const Duration(seconds: 60),
      );
    }
    if (code.isNotEmpty && code != 'OK') {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'UPCitemdb rejected the lookup code.',
      );
    }

    final rawItems = root['items'];
    if (rawItems is! List) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'UPCitemdb sent an unexpected item list.',
      );
    }

    final candidates = <MetadataCandidate>[];
    for (final entry in rawItems) {
      final item = jsonMap(entry);
      if (item == null) {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'UPCitemdb sent an item Lyberry could not read.',
        );
      }
      final title = jsonString(item['title']).trim();
      if (title.isEmpty) continue;
      final brand = jsonString(item['brand']).trim();
      final category = jsonString(item['category']).trim();
      final description = jsonString(item['description']).trim();
      final images = jsonList(
        item['images'],
      ).map(jsonString).where((url) => url.isNotEmpty);
      final codes = <String>[
        for (final key in <String>['ean', 'upc', 'isbn']) jsonString(item[key]),
      ].where((value) => value.isNotEmpty);

      candidates.add(
        MetadataCandidate(
          providerId: id,
          providerLabel: label,
          externalId: _externalId(item, title),
          matchKind: codes.any(identifier.matches)
              ? MatchKind.exact
              : MatchKind.possible,
          title: title,
          medium: _mediumFor(category, title),
          creator: brand,
          publisher: brand,
          description: description.isNotEmpty
              ? description
              : category.isEmpty
              ? ''
              : 'Category: $category',
          coverUrl: images.isEmpty ? null : images.first,
        ),
      );
    }
    return ProviderLookupResult(candidates: candidates);
  }

  /// `X-RateLimit-Reset` is an absolute Unix timestamp in seconds.
  Duration? _resetDelay(TransportResponse response) {
    final header = response.header('x-ratelimit-reset');
    if (header == null) return null;
    return resetDelayFromEpoch(header, clock: _clock);
  }

  String _externalId(Map<String, Object?> item, String title) {
    for (final key in <String>['ean', 'upc', 'isbn', 'model']) {
      final value = jsonString(item[key]).trim();
      if (value.isNotEmpty) return value;
    }
    return title.toLowerCase();
  }

  MediaType? _mediumFor(String category, String title) {
    final text = '$category $title'.toLowerCase();
    if (text.contains('vinyl') || text.contains(' lp')) return MediaType.vinyl;
    if (text.contains('blu-ray') || text.contains('bluray')) {
      return MediaType.bluray;
    }
    if (text.contains('dvd')) return MediaType.dvd;
    if (text.contains('video game') ||
        text.contains('game') ||
        text.contains('console')) {
      return MediaType.game;
    }
    if (text.contains('book') ||
        text.contains('paperback') ||
        text.contains('hardcover')) {
      return MediaType.book;
    }
    if (text.contains('music') ||
        text.contains('cd') ||
        text.contains('audio')) {
      return MediaType.cd;
    }
    return null;
  }
}
