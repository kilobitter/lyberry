import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/state/item_draft.dart';

import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

MetadataCandidate candidateFor(MediaType medium) => MetadataCandidate(
  providerId: 'upcitemdb',
  providerLabel: 'UPCitemdb',
  externalId: 'external-1',
  matchKind: MatchKind.possible,
  title: 'Provider title',
  medium: medium,
);

void main() {
  test('only books and films are finishable', () {
    expect(MediaType.book.isFinishable, isTrue);
    expect(MediaType.dvd.isFinishable, isTrue);
    expect(MediaType.bluray.isFinishable, isTrue);
    expect(MediaType.cd.isFinishable, isFalse);
    expect(MediaType.vinyl.isFinishable, isFalse);
    expect(MediaType.game.isFinishable, isFalse);
  });

  group('MediaItem.isFinished', () {
    test('defaults to false and survives serialization both ways', () {
      final item = sampleItem(id: '00000000-0000-4000-8000-000000000001');

      expect(item.isFinished, isFalse);
      expect(item.toJson()['isFinished'], isFalse);
      expect(MediaItem.fromJson(item.toJson()).isFinished, isFalse);

      final finished = item.copyWith(isFinished: true);
      expect(finished.isFinished, isTrue);
      expect(finished.toJson()['isFinished'], isTrue);
      expect(MediaItem.fromJson(finished.toJson()).isFinished, isTrue);
    });

    test('legacy payloads without the field decode as not finished', () {
      final json = sampleItem(
        id: '00000000-0000-4000-8000-000000000002',
      ).toJson()..remove('isFinished');

      expect(MediaItem.fromJson(json).isFinished, isFalse);
    });

    test('a present but non-boolean value is rejected', () {
      for (final bad in <Object?>[null, 0, 1, 'true', <String>[]]) {
        final json = sampleItem(
          id: '00000000-0000-4000-8000-000000000003',
        ).toJson()..['isFinished'] = bad;
        expect(
          () => MediaItem.fromJson(json),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('copyWith preserves it, equality and hashCode include it', () {
      final item = sampleItem(id: '00000000-0000-4000-8000-000000000004');
      final finished = item.copyWith(isFinished: true);

      expect(item.copyWith(title: 'Other').isFinished, isFalse);
      expect(finished.copyWith(title: 'Other').isFinished, isTrue);
      expect(finished.copyWith(isFinished: false).isFinished, isFalse);
      expect(finished == item, isFalse);
      expect(finished.hashCode == item.hashCode, isFalse);
    });
  });

  group('ItemDraft.isFinished', () {
    test('starts false for manual and provider copies', () {
      expect(
        ItemDraft(medium: MediaType.book, title: 'New').isFinished,
        isFalse,
      );
      expect(
        ItemDraft.fromCandidate(candidateFor(MediaType.book)).isFinished,
        isFalse,
      );
    });

    test('round-trips through a draft and the built item', () {
      final item = sampleItem(
        id: '00000000-0000-4000-8000-000000000005',
        isFinished: true,
      );
      final draft = ItemDraft.fromItem(item);

      expect(draft.isFinished, isTrue);
      final rebuilt = draft.buildItem(
        id: item.id,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt,
      );
      expect(rebuilt.isFinished, isTrue);
      expect(rebuilt, item);
    });
  });

  test(
    'a duplicate copy resets the flag and the original stays finished',
    () async {
      final repository = InMemoryMediaRepository();
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000006',
          isFinished: true,
        ),
      );

      final copy = await repository.createCopy(
        '00000000-0000-4000-8000-000000000006',
      );

      expect(copy.isFinished, isFalse);
      expect(
        (await repository.getItem(
          '00000000-0000-4000-8000-000000000006',
        ))!.isFinished,
        isTrue,
      );
    },
  );
}
