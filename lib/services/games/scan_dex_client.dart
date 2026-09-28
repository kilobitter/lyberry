import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/providers/json.dart';

/// One ScanDex identification result.
class ScanDexMatch {
  const ScanDexMatch({
    required this.source,
    required this.igdbId,
    required this.title,
    this.platformId,
    this.platformName,
  });

  /// ScanDex v2 uses `import` for a maintained mapping and `user` for a
  /// community-supplied entry. `imported` is tolerated for older/other
  /// spellings seen in the wild, but the documented literal is `import`.
  final String source;
  final int igdbId;
  final String title;
  final int? platformId;
  final String? platformName;

  /// Community entries are never presented as an exact identification.
  bool get isCommunity => source.toLowerCase() == 'user';

  bool get isImported {
    final value = source.toLowerCase();
    return value == 'import' || value == 'imported';
  }
}

/// ScanDex v2 barcode identification.
///
/// The code travels as the `value` query parameter and the personal API token
/// as a raw `Authorization` header (ScanDex does not use the `Bearer` prefix).
/// A 404, `status: unmatched` or a missing `igdb_metadata` block all mean "no
/// match" rather than a malformed answer.
class ScanDexClient {
  ScanDexClient({
    required GamesTransport transport,
    required String token,
    this.timeout = GamesEndpointLimits.scanDexTimeout,
  }) : _transport = transport,
       _token = token;

  static const int maxBytes = 512 * 1024;

  final GamesTransport _transport;
  final String _token;
  final Duration timeout;

  Future<ScanDexMatch?> lookup(String code) async {
    final uri = GamesEndpoint.scanDexLookup.uri(<String, String>{
      'value': code,
    });
    final response = await _transport.send(
      GamesRequest(
        endpoint: GamesEndpoint.scanDexLookup,
        uri: uri,
        headers: <String, String>{'Authorization': _token},
      ),
      timeout: timeout,
      maxBytes: maxBytes,
    );

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw gamesStatusException(response.statusCode, 'ScanDex');
    }

    final root = jsonMap(decodeGamesJson(response.body, 'ScanDex'));
    if (root == null) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'ScanDex sent an unexpected response shape.',
      );
    }
    final status = jsonString(root['status']).trim().toLowerCase();
    if (status == 'unmatched' || status == 'not_found') return null;

    final metadata = jsonMap(root['igdb_metadata']);
    if (metadata == null) return null;

    final igdbId = jsonInt(metadata['id']);
    if (igdbId == null || igdbId <= 0) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'ScanDex sent an unexpected game id.',
      );
    }
    final title = jsonString(metadata['name']).trim();
    if (title.isEmpty) {
      throw const ProviderException(
        LookupFailureKind.malformed,
        'ScanDex sent a match without a game name.',
      );
    }
    final platform = jsonMap(metadata['platform']);
    final rawPlatformId = jsonInt(platform?['id']);
    final platformId = rawPlatformId != null && rawPlatformId > 0
        ? rawPlatformId
        : null;
    final platformName = jsonString(platform?['name']).trim();

    return ScanDexMatch(
      source: jsonString(root['source']).trim(),
      igdbId: igdbId,
      title: title,
      platformId: platformId,
      platformName: platformName.isEmpty ? null : platformName,
    );
  }
}
