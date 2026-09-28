import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lyberry/domain/web_lookup.dart';

/// One stored credential: a user-facing label plus its persisted key name.
///
/// Persisted names are stable; never rename an existing value.
abstract interface class CredentialKey {
  String get label;
  String get storageKey;

  /// Short, stable identifier used for Settings widget keys.
  String get slug;
}

/// Which paid web provider a key belongs to.
enum WebKeyProvider implements CredentialKey {
  tavily('Tavily', 'lyberry.web.tavily_key'),
  deepseek('DeepSeek', 'lyberry.web.deepseek_key');

  const WebKeyProvider(this.label, this.storageKey);

  @override
  final String label;

  @override
  final String storageKey;

  @override
  String get slug => name;
}

/// Credentials for the development-only personal games lookup.
///
/// A public release is expected to move these shared developer credentials to a
/// server-side proxy; here they are stored per device so the owner can test.
enum GamesKeyProvider implements CredentialKey {
  scandex('ScanDex API token', 'lyberry.games.scandex_token'),
  twitchId('Twitch client ID', 'lyberry.games.twitch_client_id'),
  twitchSecret('Twitch client secret', 'lyberry.games.twitch_client_secret');

  const GamesKeyProvider(this.label, this.storageKey);

  @override
  final String label;

  @override
  final String storageKey;

  @override
  String get slug => name;
}

/// Credentials for the personal UPCMDB movie lookup.
///
/// UPCMDB is a paid third-party service billed to the user's own key; Lyberry
/// has no backend and bundles no key. The stored value is never written to an
/// export, log, source file or screenshot.
enum MovieKeyProvider implements CredentialKey {
  upcmdb('UPCMDB API key', 'lyberry.movies.upcmdb_key');

  const MovieKeyProvider(this.label, this.storageKey);

  @override
  final String label;

  @override
  final String storageKey;

  @override
  String get slug => name;
}

/// Small injectable seam so tests can substitute an in-memory store.
abstract interface class ApiKeyStore {
  Future<bool> has(CredentialKey provider);

  /// Returns the stored key, or `null` when nothing is configured.
  Future<String?> read(CredentialKey provider);

  /// Throws [WebLookupException] when the value cannot be persisted.
  Future<void> write(CredentialKey provider, String value);

  /// Throws [WebLookupException] when the value cannot be removed.
  Future<void> remove(CredentialKey provider);
}

/// Rejects blank, control-character and oversized key values without making any
/// assumption about vendor prefixes.
String? describeApiKeyProblem(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 'Enter the key first.';
  if (trimmed.length > maxApiKeyLength) {
    return 'This key is longer than $maxApiKeyLength characters.';
  }
  for (final rune in trimmed.runes) {
    if (rune < 0x21 || rune == 0x7f) {
      return 'Keys cannot contain spaces or control characters.';
    }
  }
  return null;
}

const int maxApiKeyLength = 512;

/// Platform key store backed by the OS keystore / keychain.
///
/// Android uses the plugin's Keystore-encrypted storage; iOS uses a
/// non-synchronizing, this-device-only keychain item. There is no plaintext
/// fallback: a persistence failure is surfaced instead of pretending to save.
class SecureApiKeyStore implements ApiKeyStore {
  SecureApiKeyStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
            aOptions: AndroidOptions(),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<bool> has(CredentialKey provider) async {
    // A storage failure is not "not configured": it is surfaced so Settings can
    // say the keystore is unavailable instead of inviting a pointless retry.
    return await read(provider) != null;
  }

  @override
  Future<String?> read(CredentialKey provider) async {
    try {
      final value = await _storage.read(key: provider.storageKey);
      if (value == null || value.trim().isEmpty) return null;
      return value;
    } on Object {
      throw WebLookupException(
        WebFailureKind.unavailable,
        '${provider.label} key could not be read on this device.',
        stage: WebLookupStage.keys,
      );
    }
  }

  @override
  Future<void> write(CredentialKey provider, String value) async {
    final problem = describeApiKeyProblem(value);
    if (problem != null) {
      throw WebLookupException(
        WebFailureKind.missingKey,
        problem,
        stage: WebLookupStage.keys,
      );
    }
    try {
      final intended = value.trim();
      await _storage.write(key: provider.storageKey, value: intended);
      final stored = await _storage.read(key: provider.storageKey);
      // Reading back a stale value is a failed replacement, not a success.
      if (stored != intended) {
        throw WebLookupException(
          WebFailureKind.unavailable,
          '${provider.label} key was not stored correctly on this device.',
          stage: WebLookupStage.keys,
        );
      }
    } on WebLookupException {
      rethrow;
    } on Object {
      throw WebLookupException(
        WebFailureKind.unavailable,
        '${provider.label} key could not be saved on this device.',
        stage: WebLookupStage.keys,
      );
    }
  }

  @override
  Future<void> remove(CredentialKey provider) async {
    try {
      await _storage.delete(key: provider.storageKey);
      final left = await _storage.read(key: provider.storageKey);
      if (left != null && left.trim().isNotEmpty) {
        throw WebLookupException(
          WebFailureKind.unavailable,
          '${provider.label} key is still stored.',
          stage: WebLookupStage.keys,
        );
      }
    } on WebLookupException {
      rethrow;
    } on Object {
      throw WebLookupException(
        WebFailureKind.unavailable,
        '${provider.label} key could not be removed on this device.',
        stage: WebLookupStage.keys,
      );
    }
  }
}
