import 'dart:convert';

import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/providers/json.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/transport.dart';
import 'package:lyberry/services/user_agent.dart';

/// MusicBrainz release lookup by barcode, with Cover Art Archive thumbnails.
class MusicBrainzProvider implements MetadataProvider {
  MusicBrainzProvider({
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
  String get id => 'musicbrainz';

  @override
  String get label => 'MusicBrainz';

  @override
  Set<ProviderRole> get roles => const <ProviderRole>{ProviderRole.music};

  @override
  bool supports(MediaType? mediumHint) => switch (mediumHint) {
    null ||
    MediaType.cd ||
    MediaType.vinyl ||
    MediaType.dvd ||
    MediaType.bluray => true,
    _ => false,
  };

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    final identifier = query.identifier;
    final uri = Uri.https('musicbrainz.org', '/ws/2/release/', <String, String>{
      'query': 'barcode:${identifier.canonicalKey}',
      'fmt': 'json',
      'limit': '10',
    });

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

    if (response.statusCode == 429 || response.statusCode == 503) {
      throw ProviderException(
        LookupFailureKind.quota,
        'MusicBrainz is rate limiting lookups.',
        retryAfter:
            parseRetryAfter(response.header('retry-after'), clock: _clock) ??
            const Duration(seconds: 5),
      );
    }
    if (response.statusCode >= 400) {
      throw ProviderException(
        LookupFailureKind.http,
        'MusicBrainz answered ${response.statusCode}.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'MusicBrainz sent a response Lyberry could not read.',
      );
    }
    final root = jsonMap(decoded);
    if (root == null) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'MusicBrainz sent an unexpected response shape.',
      );
    }
    final rawReleases = root['releases'];
    if (rawReleases is! List) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'MusicBrainz sent an unexpected release list.',
      );
    }

    final candidates = <MetadataCandidate>[];
    for (final entry in rawReleases) {
      final release = jsonMap(entry);
      if (release == null) {
        throw const ProviderException(
          LookupFailureKind.malformed,
          'MusicBrainz sent a release Lyberry could not read.',
        );
      }
      final releaseId = jsonString(release['id']);
      final title = jsonString(release['title']).trim();
      if (releaseId.isEmpty || title.isEmpty) continue;
      final barcode = jsonString(release['barcode']);
      final media = jsonList(
        release['media'],
      ).map(jsonMap).whereType<Map<String, Object?>>().toList();
      final format = media.isEmpty ? '' : jsonString(media.first['format']);

      candidates.add(
        MetadataCandidate(
          providerId: id,
          providerLabel: label,
          externalId: releaseId,
          matchKind: identifier.matches(barcode)
              ? MatchKind.exact
              : MatchKind.possible,
          title: title,
          medium: _mediumFor(format, query.mediumHint),
          creator: _artist(release),
          year: jsonYear(release['date']),
          publisher: _label(release),
          platform: format,
          coverUrl: 'https://coverartarchive.org/release/$releaseId/front-250',
          sourceUrl: 'https://musicbrainz.org/release/$releaseId',
        ),
      );
    }
    return ProviderLookupResult(candidates: candidates);
  }

  String _artist(Map<String, Object?> release) {
    final credits = jsonList(release['artist-credit']);
    final names = <String>[];
    for (final entry in credits) {
      final credit = jsonMap(entry);
      if (credit == null) continue;
      final name = jsonString(credit['name']).trim();
      if (name.isNotEmpty) names.add(name);
    }
    return names.join(', ');
  }

  String _label(Map<String, Object?> release) {
    for (final entry in jsonList(release['label-info'])) {
      final info = jsonMap(entry);
      if (info == null) continue;
      final label = jsonMap(info['label']);
      final name = jsonString(label?['name']).trim();
      if (name.isNotEmpty) return name;
    }
    return '';
  }

  /// Suggests the physical family from the release format, falling back to the
  /// scanner's medium hint.
  MediaType? _mediumFor(String format, MediaType? hint) {
    final lower = format.toLowerCase();
    if (lower.contains('vinyl') ||
        lower.contains('12"') ||
        lower.contains('7"') ||
        lower.contains('lp')) {
      return MediaType.vinyl;
    }
    if (lower.contains('blu-ray') || lower.contains('bluray')) {
      return MediaType.bluray;
    }
    if (lower.contains('dvd')) return MediaType.dvd;
    if (lower.contains('cd')) return MediaType.cd;
    return hint;
  }
}
