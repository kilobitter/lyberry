import 'dart:collection';

import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:lyberry/services/transport.dart';

/// Conservative cover-art downloader.
///
/// Only allowlisted HTTPS hosts on port 443 are contacted, every redirect hop is
/// re-validated, responses are byte- and time-capped, and the bytes must decode
/// as one static image. Any failure returns `null`: covers never block saving a
/// record, and imported backups never trigger requests.
class CoverDownloader {
  CoverDownloader({
    required HttpTransport transport,
    ImageIngest ingest = const ImageIngest(),
    this.timeout = const Duration(seconds: 10),
    this.maxBytes = 2 * 1024 * 1024,
    this.maxRedirects = 3,
    Set<String>? allowedHosts,
    int cacheEntries = 24,
  }) : _transport = transport,
       _ingest = ingest,
       _allowedHosts = allowedHosts ?? defaultAllowedHosts,
       _cacheEntries = cacheEntries;

  /// Public cover hosts Lyberry is willing to contact.
  static const Set<String> defaultAllowedHosts = <String>{
    'covers.openlibrary.org',
    'coverartarchive.org',
    'archive.org',
    'm.media-amazon.com',
    'images-na.ssl-images-amazon.com',
    'i.ebayimg.com',
    'i5.walmartimages.com',
    // IGDB cover art, built only from a validated image_id.
    'images.igdb.com',
  };

  final HttpTransport _transport;
  final ImageIngest _ingest;
  final Duration timeout;
  final int maxBytes;
  final int maxRedirects;
  final Set<String> _allowedHosts;
  final int _cacheEntries;

  final LinkedHashMap<String, MediaAsset> _cache =
      LinkedHashMap<String, MediaAsset>();

  int get cacheLength => _cache.length;

  Future<MediaAsset?> download(String url) async {
    final cached = _cache.remove(url);
    if (cached != null) {
      _cache[url] = cached;
      return cached;
    }

    final parsed = Uri.tryParse(url);
    if (parsed == null) return null;
    if (!isAllowedUri(parsed, allowedHosts: _allowedHosts)) return null;
    var uri = parsed;

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final TransportResponse response;
      try {
        response = await _transport.get(
          uri,
          timeout: timeout,
          maxBytes: maxBytes,
          followRedirects: false,
        );
      } on TransportException {
        return null;
      } on Object {
        // Any unexpected transport problem degrades to "no cover" rather than
        // escaping into an unawaited editor fetch.
        return null;
      }

      try {
        if (_isRedirect(response.statusCode)) {
          final location = response.header('location');
          if (location == null || location.trim().isEmpty) return null;
          final next = uri.resolve(location.trim());
          if (!isAllowedUri(next, allowedHosts: _allowedHosts)) return null;
          uri = next;
          continue;
        }
      } on Object {
        return null;
      }
      if (response.statusCode != 200) return null;

      try {
        final asset = _ingest.buildAsset(response.bytes, field: 'cover');
        _remember(url, asset);
        return asset;
      } on Object {
        return null;
      }
    }
    return null;
  }

  void _remember(String url, MediaAsset asset) {
    _cache[url] = asset;
    while (_cache.length > _cacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  /// True only for an allowlisted HTTPS host on port 443 with no userinfo and
  /// no literal or private address.
  static bool isAllowedUri(Uri uri, {Set<String>? allowedHosts}) {
    if (uri.scheme != 'https') return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.hasPort && uri.port != 443) return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty || isBlockedHost(host)) return false;
    final allowlist = allowedHosts ?? defaultAllowedHosts;
    if (allowlist.contains(host)) return true;
    for (final allowed in allowlist) {
      if (host.endsWith('.$allowed')) return true;
    }
    return false;
  }

  /// Rejects loopback, private, link-local and literal-address hosts.
  static bool isBlockedHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower.endsWith('.localhost')) return true;
    if (lower.startsWith('[')) return true; // IPv6 literal
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
    final match = ipv4.firstMatch(lower);
    if (match == null) return false;
    final parts = <int>[
      for (var index = 1; index <= 4; index++) int.parse(match.group(index)!),
    ];
    if (parts.any((part) => part > 255)) return true;
    if (parts[0] == 10 || parts[0] == 127 || parts[0] == 0) return true;
    if (parts[0] == 169 && parts[1] == 254) return true;
    if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return true;
    if (parts[0] == 192 && parts[1] == 168) return true;
    return false;
  }
}
