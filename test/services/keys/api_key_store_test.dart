import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/keys/api_key_store.dart';

import '../../support/fake_web.dart';

void main() {
  test('validates key input without vendor prefix assumptions', () {
    expect(describeApiKeyProblem(''), isNotNull);
    expect(describeApiKeyProblem('   '), isNotNull);
    expect(describeApiKeyProblem('key with space'), isNotNull);
    expect(describeApiKeyProblem('key\nnewline'), isNotNull);
    expect(describeApiKeyProblem('a' * (maxApiKeyLength + 1)), isNotNull);
    expect(describeApiKeyProblem('tvly-abc123'), isNull);
    expect(describeApiKeyProblem('sk-and-a-longer-value-1234'), isNull);
  });

  test('separate synthetic keys round-trip and delete independently', () async {
    final store = InMemoryApiKeyStore();
    await store.write(WebKeyProvider.tavily, 'tvly-synthetic-1');
    await store.write(WebKeyProvider.deepseek, 'sk-synthetic-2');

    expect(await store.has(WebKeyProvider.tavily), isTrue);
    expect(await store.read(WebKeyProvider.tavily), 'tvly-synthetic-1');
    expect(await store.read(WebKeyProvider.deepseek), 'sk-synthetic-2');

    await store.remove(WebKeyProvider.tavily);
    expect(await store.has(WebKeyProvider.tavily), isFalse);
    expect(await store.read(WebKeyProvider.tavily), isNull);
    expect(await store.has(WebKeyProvider.deepseek), isTrue);
  });

  test('a failed write or remove is surfaced, never claimed', () async {
    final store = InMemoryApiKeyStore();
    store.writeFailure = const WebLookupException(
      WebFailureKind.unavailable,
      'Tavily key could not be saved on this device.',
      stage: WebLookupStage.keys,
    );
    WebLookupException? writeError;
    try {
      await store.write(WebKeyProvider.tavily, 'tvly-synthetic');
    } on WebLookupException catch (error) {
      writeError = error;
    }
    expect(writeError?.kind, WebFailureKind.unavailable);
    expect(await store.has(WebKeyProvider.tavily), isFalse);

    store.writeFailure = null;
    await store.write(WebKeyProvider.deepseek, 'sk-synthetic');
    store.removeFailure = const WebLookupException(
      WebFailureKind.unavailable,
      'DeepSeek key could not be removed on this device.',
      stage: WebLookupStage.keys,
    );
    WebLookupException? removeError;
    try {
      await store.remove(WebKeyProvider.deepseek);
    } on WebLookupException catch (error) {
      removeError = error;
    }
    expect(removeError?.kind, WebFailureKind.unavailable);
    expect(await store.has(WebKeyProvider.deepseek), isTrue);
  });

  test('rejects invalid values without storing them', () async {
    final store = InMemoryApiKeyStore();
    WebLookupException? error;
    try {
      await store.write(WebKeyProvider.tavily, 'has space');
    } on WebLookupException catch (caught) {
      error = caught;
    }
    expect(error?.kind, WebFailureKind.missingKey);
    expect(store.peek(WebKeyProvider.tavily), isNull);
  });
}
