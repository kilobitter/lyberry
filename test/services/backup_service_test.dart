import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/image_ingest.dart';

import '../support/fake_snapshot_io.dart';
import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

BackupService serviceFor(
  InMemoryMediaRepository repository,
  FakeSnapshotIo io,
) => BackupService(
  repository: repository,
  io: io,
  clock: FixedClock(kBaseTime),
  useIsolate: false,
);

void main() {
  test('export writes a portable payload with counts and images', () async {
    final repository = InMemoryMediaRepository();
    final photo = const ImageIngest().buildAsset(pngBytes(width: 8, height: 8));
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Dune',
        photoAssetIds: <String>[photo.id],
      ),
      assets: <MediaAsset>[photo],
    );
    final io = FakeSnapshotIo();

    final result = await serviceFor(repository, io).export();

    expect(result.cancelled, isFalse);
    expect(result.items, 1);
    expect(result.assets, 1);
    expect(io.savedFileName, startsWith('lyberry-'));
    expect(io.savedFileName, endsWith('.lyberry.json'));

    final decoded = SnapshotCodec.decode(io.savedContents!);
    expect(decoded.items.single.title, 'Dune');
    expect(decoded.assets.single.bytes, photo.bytes);
  });

  test('a cancelled save is reported and writes nothing', () async {
    final repository = InMemoryMediaRepository();
    final io = FakeSnapshotIo(saveResult: false);

    final result = await serviceFor(repository, io).export();

    expect(result.cancelled, isTrue);
    expect(result.items, 0);
  });

  test('import preview counts additions and replacements', () async {
    final source = InMemoryMediaRepository();
    await source.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-00000000000a',
        title: 'From the file',
      ),
    );
    await source.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-00000000000b',
        title: 'Only in the file',
      ),
    );
    final sourceIo = FakeSnapshotIo();
    await serviceFor(source, sourceIo).export();

    final target = InMemoryMediaRepository();
    await target.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-00000000000a',
        title: 'Local version',
      ),
    );
    await target.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-00000000000c',
        title: 'Local only',
      ),
    );

    final io = FakeSnapshotIo(
      pickResult: PickedBackup(
        fileName: 'lyberry-backup.lyberry.json',
        contents: sourceIo.savedContents!,
        byteLength: sourceIo.savedContents!.length,
      ),
    );
    final service = serviceFor(target, io);

    final preview = await service.chooseImport();

    expect(preview, isNotNull);
    expect(preview!.added, 1);
    expect(preview.updated, 1);
    expect(preview.total, 2);

    final result = await service.apply(preview.snapshot);
    expect(result.added, 1);
    expect(result.updated, 1);

    final items = await target.listItems();
    expect(items, hasLength(3));
    expect(
      items.firstWhere((item) => item.id.endsWith('a')).title,
      'From the file',
    );
    expect(
      items.firstWhere((item) => item.id.endsWith('c')).title,
      'Local only',
      reason: 'copies absent from the file must stay untouched',
    );
  });

  test(
    'incoming data wins even when it is older, and re-import is idempotent',
    () async {
      final source = InMemoryMediaRepository();
      final photo = const ImageIngest().buildAsset(
        jpegBytes(width: 10, height: 10),
      );
      await source.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-0000000000aa',
          title: 'Older incoming',
          rating: 3.0,
          photoAssetIds: <String>[photo.id],
          createdAt: '2026-09-01T10:00:00.000Z',
          updatedAt: '2026-09-02T10:00:00.000Z',
        ),
        assets: <MediaAsset>[photo],
      );
      final sourceIo = FakeSnapshotIo();
      await serviceFor(source, sourceIo).export();

      final target = InMemoryMediaRepository();
      await target.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-0000000000aa',
          title: 'Newer local',
          rating: 5.0,
          createdAt: '2026-09-20T10:00:00.000Z',
          updatedAt: '2026-09-21T10:00:00.000Z',
        ),
      );

      final io = FakeSnapshotIo(
        pickResult: PickedBackup(
          fileName: 'backup.lyberry.json',
          contents: sourceIo.savedContents!,
          byteLength: sourceIo.savedContents!.length,
        ),
      );
      final service = serviceFor(target, io);

      final preview = await service.chooseImport();
      expect(preview!.updated, 1);
      final first = await service.apply(preview.snapshot);
      expect(first.updated, 1);
      expect(first.assetsAdded, 1);

      final stored = (await target.listItems()).single;
      expect(stored.title, 'Older incoming');
      expect(stored.rating, 3.0);
      expect(stored.updatedAt, '2026-09-02T10:00:00.000Z');
      final storedPhoto = await target.getAsset(stored.photoAssetIds.single);
      expect(storedPhoto?.bytes, photo.bytes);

      final secondPreview = await service.chooseImport();
      final second = await service.apply(secondPreview!.snapshot);
      expect(second.added, 0);
      expect(second.updated, 1);
      expect(
        second.assetsAdded,
        0,
        reason: 'image bytes are content addressed',
      );
      expect(await target.countItems(), 1);
    },
  );

  test(
    'two copies that share a barcode stay separate across a backup',
    () async {
      final source = InMemoryMediaRepository();
      await source.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-0000000000c1',
          title: 'Dune',
          barcode: '9780306406157',
          createdAt: '2026-09-23T10:00:00.000Z',
          updatedAt: '2026-09-23T10:00:00.000Z',
        ),
      );
      await source.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-0000000000c2',
          title: 'Dune (second copy)',
          barcode: '9780306406157',
          createdAt: '2026-09-23T11:00:00.000Z',
          updatedAt: '2026-09-23T11:00:00.000Z',
        ),
      );
      final sourceIo = FakeSnapshotIo();
      await serviceFor(source, sourceIo).export();

      final target = InMemoryMediaRepository();
      final io = FakeSnapshotIo(
        pickResult: PickedBackup(
          fileName: 'backup.lyberry.json',
          contents: sourceIo.savedContents!,
          byteLength: sourceIo.savedContents!.length,
        ),
      );
      final service = serviceFor(target, io);
      final preview = await service.chooseImport();
      await service.apply(preview!.snapshot);

      final items = await target.listItems();
      expect(items, hasLength(2));
      expect(items.map((item) => item.barcode).toSet(), <String>{
        '9780306406157',
      });
    },
  );
}
