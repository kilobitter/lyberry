import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/backup_service.dart';

import '../support/fake_snapshot_io.dart';
import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

Map<String, Object?> itemJson({
  required String id,
  Object? isFinished = false,
  bool include = true,
}) {
  final json = sampleItem(id: id).toJson()..remove('isFinished');
  if (include) json['isFinished'] = isFinished;
  return json;
}

Map<String, Object?> payload({
  int version = LibrarySnapshot.schemaVersion,
  List<Object?>? items,
}) => <String, Object?>{
  'format': 'lyberry',
  'schemaVersion': version,
  'exportedAt': kBaseTimestamp,
  'items':
      items ?? <Object?>[itemJson(id: '00000000-0000-4000-8000-0000000000a1')],
  'assets': <Object?>[],
};

void main() {
  test('exports schema 2 and round-trips both finished states', () {
    final snapshot = LibrarySnapshot(
      exportedAt: kBaseTimestamp,
      items: <MediaItem>[
        sampleItem(
          id: '00000000-0000-4000-8000-0000000000b1',
          isFinished: true,
        ),
        sampleItem(id: '00000000-0000-4000-8000-0000000000b2'),
      ],
      assets: const <MediaAsset>[],
    );

    final encoded = SnapshotCodec.encode(snapshot);
    expect(encoded, contains('"schemaVersion":2'));

    final decoded = SnapshotCodec.decode(encoded);
    expect(decoded.items.map((item) => item.isFinished).toList(), <bool>[
      true,
      false,
    ]);
  });

  test('a schema 2 copy must state the flag', () {
    final missing = payload(
      items: <Object?>[
        itemJson(id: '00000000-0000-4000-8000-0000000000b3', include: false),
      ],
    );

    expect(
      () => SnapshotCodec.decodeMap(missing),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('isFinished'),
        ),
      ),
    );
  });

  test('a present but non-boolean flag is rejected in schema 2 and 1', () {
    for (final version in <int>[2, 1]) {
      for (final bad in <Object?>[null, 'true', 1]) {
        final json = payload(
          version: version,
          items: <Object?>[
            itemJson(
              id: '00000000-0000-4000-8000-0000000000b4',
              isFinished: bad,
            ),
          ],
        );
        expect(
          () => SnapshotCodec.decodeMap(json),
          throwsA(isA<ValidationException>()),
          reason: 'schema $version, value $bad',
        );
      }
    }
  });

  test(
    'a schema 1 backup defaults the flag, and honours an explicit value',
    () {
      final legacy = payload(
        version: 1,
        items: <Object?>[
          itemJson(id: '00000000-0000-4000-8000-0000000000b5', include: false),
        ],
      );
      expect(SnapshotCodec.decodeMap(legacy).items.single.isFinished, isFalse);

      final explicit = payload(
        version: 1,
        items: <Object?>[
          itemJson(
            id: '00000000-0000-4000-8000-0000000000b6',
            isFinished: true,
          ),
        ],
      );
      expect(SnapshotCodec.decodeMap(explicit).items.single.isFinished, isTrue);
    },
  );

  test('imports replace the flag in both directions', () async {
    final repository = InMemoryMediaRepository();
    const id = '00000000-0000-4000-8000-0000000000b7';
    await repository.createItem(sampleItem(id: id, isFinished: true));
    final service = BackupService(
      repository: repository,
      io: FakeSnapshotIo(),
      clock: FixedClock(kBaseTime),
      useIsolate: false,
    );

    await service.apply(
      SnapshotCodec.decodeMap(
        payload(items: <Object?>[itemJson(id: id, isFinished: false)]),
      ),
    );
    expect((await repository.getItem(id))!.isFinished, isFalse);

    await service.apply(
      SnapshotCodec.decodeMap(
        payload(items: <Object?>[itemJson(id: id, isFinished: true)]),
      ),
    );
    expect((await repository.getItem(id))!.isFinished, isTrue);
  });

  test(
    'a malformed schema 2 file writes nothing through chooseImport',
    () async {
      final repository = InMemoryMediaRepository();
      const existingId = '00000000-0000-4000-8000-0000000000b8';
      const newId = '00000000-0000-4000-8000-0000000000b9';
      await repository.createItem(sampleItem(id: existingId, isFinished: true));
      final before = await repository.getItem(existingId);

      // One perfectly valid new copy and one malformed existing copy: the whole
      // import must be refused before anything is written.
      final contents = jsonEncode(
        payload(
          items: <Object?>[
            itemJson(id: newId, isFinished: false),
            itemJson(id: existingId, include: false),
          ],
        ),
      );
      final service = BackupService(
        repository: repository,
        io: FakeSnapshotIo(
          pickResult: PickedBackup(
            fileName: 'half-broken.lyberry.json',
            contents: contents,
            byteLength: contents.length,
          ),
        ),
        clock: FixedClock(kBaseTime),
        useIsolate: false,
      );

      await expectLater(
        service.chooseImport(),
        throwsA(isA<ValidationException>()),
      );
      expect(await repository.getItem(existingId), before);
      expect(await repository.getItem(newId), isNull);
      expect(await repository.countItems(), 1);
    },
  );
}
