import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/metadata_service.dart';

/// Provider that answers only when the test releases it.
class _HeldProvider implements MetadataProvider {
  _HeldProvider({this.candidates = const <MetadataCandidate>[]});

  final List<MetadataCandidate> candidates;
  final Completer<void> _release = Completer<void>();
  int calls = 0;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  String get id => 'held';

  @override
  String get label => 'Held';

  @override
  Set<ProviderRole> get roles => const <ProviderRole>{ProviderRole.general};

  @override
  bool supports(MediaType? mediumHint) => true;

  @override
  Future<ProviderLookupResult> lookup(LookupQuery query) async {
    calls++;
    await _release.future;
    return ProviderLookupResult(candidates: candidates);
  }
}

void main() {
  LookupQuery query() => LookupQuery(
    identifier: IdentifierNormalizer.normalize('045496367619'),
    mediumHint: MediaType.game,
  );

  test(
    'an in-flight answer from before an invalidation is not cached',
    () async {
      final provider = _HeldProvider();
      final cache = LookupCache();
      final service = MetadataService(
        providers: <MetadataProvider>[provider],
        cache: cache,
      );

      final pending = service.lookup(query());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Credentials changed while the provider was still answering.
      service.invalidateCache();
      provider.release();

      final outcome = await pending;
      expect(outcome.candidates, isEmpty);
      expect(cache.length, 0, reason: 'the stale empty answer is not accepted');

      // The next lookup must reach the provider again.
      final second = await service.lookup(query());
      expect(provider.calls, 2);
      expect(second.fromCache, isFalse);
    },
  );

  test('a clean answer from the current generation is cached', () async {
    final provider = _HeldProvider(
      candidates: <MetadataCandidate>[
        MetadataCandidate(
          providerId: 'held',
          providerLabel: 'Held',
          externalId: 'held:1',
          matchKind: MatchKind.possible,
          title: 'Held game',
          medium: MediaType.game,
        ),
      ],
    );
    final cache = LookupCache();
    final service = MetadataService(
      providers: <MetadataProvider>[provider],
      cache: cache,
    );

    final pending = service.lookup(query());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    provider.release();
    await pending;
    expect(cache.length, 1);

    final cached = await service.lookup(query());
    expect(cached.fromCache, isTrue);
    expect(provider.calls, 1);
  });
}
