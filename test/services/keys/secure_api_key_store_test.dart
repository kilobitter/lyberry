import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/keys/api_key_store.dart';

/// Ignores writes, so the store reads back the previous (stale) value.
class _StaleWritePlatform extends TestFlutterSecureStoragePlatform {
  _StaleWritePlatform(super.data);

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    // Deliberately do nothing.
  }
}

/// Fails reads or deletes to model a locked/denied keystore.
class _FailingPlatform extends TestFlutterSecureStoragePlatform {
  _FailingPlatform(
    super.data, {
    this.failRead = false,
    this.failDelete = false,
  });

  final bool failRead;
  final bool failDelete;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failRead) {
      throw PlatformException(code: 'keystore_unavailable');
    }
    return super.read(key: key, options: options);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failDelete) {
      throw PlatformException(code: 'keystore_unavailable');
    }
    return super.delete(key: key, options: options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterSecureStoragePlatform original;

  setUp(() => original = FlutterSecureStoragePlatform.instance);

  tearDown(() => FlutterSecureStoragePlatform.instance = original);

  SecureApiKeyStore storeWith(FlutterSecureStoragePlatform platform) {
    FlutterSecureStoragePlatform.instance = platform;
    return SecureApiKeyStore();
  }

  test('saves, reads back and removes through the platform keystore', () async {
    final data = <String, String>{};
    final store = storeWith(TestFlutterSecureStoragePlatform(data));

    expect(await store.has(WebKeyProvider.tavily), isFalse);
    await store.write(WebKeyProvider.tavily, 'tvly-synthetic-one');
    expect(await store.has(WebKeyProvider.tavily), isTrue);
    expect(await store.read(WebKeyProvider.tavily), 'tvly-synthetic-one');
    expect(data['lyberry.web.tavily_key'], 'tvly-synthetic-one');

    await store.remove(WebKeyProvider.tavily);
    expect(await store.has(WebKeyProvider.tavily), isFalse);
    expect(data.containsKey('lyberry.web.tavily_key'), isFalse);
  });

  test('keeps the two provider keys separate', () async {
    final data = <String, String>{};
    final store = storeWith(TestFlutterSecureStoragePlatform(data));
    await store.write(WebKeyProvider.tavily, 'tvly-synthetic');
    await store.write(WebKeyProvider.deepseek, 'sk-synthetic');
    expect(await store.read(WebKeyProvider.tavily), 'tvly-synthetic');
    expect(await store.read(WebKeyProvider.deepseek), 'sk-synthetic');
    await store.remove(WebKeyProvider.deepseek);
    expect(await store.read(WebKeyProvider.tavily), 'tvly-synthetic');
    expect(await store.read(WebKeyProvider.deepseek), isNull);
  });

  test(
    'a stale read-back after a replacement is reported as a failure',
    () async {
      final data = <String, String>{'lyberry.web.tavily_key': 'tvly-old-value'};
      final store = storeWith(_StaleWritePlatform(data));

      WebLookupException? error;
      try {
        await store.write(WebKeyProvider.tavily, 'tvly-new-value');
      } on WebLookupException catch (caught) {
        error = caught;
      }

      expect(error, isNotNull);
      expect(error!.kind, WebFailureKind.unavailable);
      // The message never carries the secret, and the stale value stays visible
      // as the stored state rather than being reported as saved.
      expect(error.message, isNot(contains('tvly-new-value')));
      expect(error.message, isNot(contains('tvly-old-value')));
      expect(await store.read(WebKeyProvider.tavily), 'tvly-old-value');
    },
  );

  test(
    'a read failure is surfaced instead of reported as not configured',
    () async {
      final store = storeWith(
        _FailingPlatform(<String, String>{}, failRead: true),
      );

      WebLookupException? error;
      try {
        await store.has(WebKeyProvider.tavily);
      } on WebLookupException catch (caught) {
        error = caught;
      }
      expect(error, isNotNull);
      expect(error!.kind, WebFailureKind.unavailable);
      expect(error.stage, WebLookupStage.keys);
      expect(error.message, contains('Tavily'));
    },
  );

  test(
    'a delete failure is surfaced and the value is not claimed removed',
    () async {
      final store = storeWith(
        _FailingPlatform(<String, String>{
          'lyberry.web.deepseek_key': 'sk-synthetic',
        }, failDelete: true),
      );

      WebLookupException? error;
      try {
        await store.remove(WebKeyProvider.deepseek);
      } on WebLookupException catch (caught) {
        error = caught;
      }
      expect(error, isNotNull);
      expect(error!.kind, WebFailureKind.unavailable);
      expect(await store.read(WebKeyProvider.deepseek), 'sk-synthetic');
    },
  );

  test('invalid input is refused before the platform is touched', () async {
    final data = <String, String>{};
    final store = storeWith(TestFlutterSecureStoragePlatform(data));
    await expectLater(
      () => store.write(WebKeyProvider.tavily, 'has space'),
      throwsA(isA<WebLookupException>()),
    );
    expect(data, isEmpty);
  });
}
