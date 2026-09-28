import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_snapshot_io.dart';
import '../support/test_support.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'export and import round-trip through the default isolate path',
    () async {
      final sourceDirectory = createTempDir('isolate_source');
      final targetDirectory = createTempDir('isolate_target');
      final source = await openTestRepository(
        '${sourceDirectory.path}/lyberry.db',
      );
      final target = await openTestRepository(
        '${targetDirectory.path}/lyberry.db',
      );
      addTearDown(() async {
        await source.close();
        await target.close();
        if (sourceDirectory.existsSync()) {
          sourceDirectory.deleteSync(recursive: true);
        }
        if (targetDirectory.existsSync()) {
          targetDirectory.deleteSync(recursive: true);
        }
      });

      final photo = const ImageIngest().buildAsset(
        pngBytes(width: 24, height: 18),
      );
      await source.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-0000000000a1',
          title: 'Isolate round trip',
          notes: 'Private note with a unicode marker.',
          rating: 4.5,
          photoAssetIds: <String>[photo.id],
        ),
        assets: <MediaAsset>[photo],
      );

      // Default BackupService: encoding runs on a worker isolate that must only
      // receive sendable snapshot/limits locals, never the service itself.
      final io = FakeSnapshotIo();
      final exporter = BackupService(
        repository: source,
        io: io,
        clock: FixedClock(kBaseTime),
      );
      final exported = await exporter.export();
      expect(exported.cancelled, isFalse);
      expect(exported.items, 1);
      expect(io.savedContents, isNotNull);

      // Default BackupService on the other side: decoding also runs off the UI
      // isolate, against a real SQLite target repository.
      final contents = io.savedContents!;
      final importer = BackupService(
        repository: target,
        io: FakeSnapshotIo(
          pickResult: PickedBackup(
            fileName: 'lyberry-isolate.lyberry.json',
            contents: contents,
            byteLength: SnapshotCodec.exactUtf8Length(contents),
          ),
        ),
        clock: FixedClock(kBaseTime),
      );
      final preview = await importer.chooseImport();
      expect(preview, isNotNull);
      expect(preview!.added, 1);
      final result = await importer.apply(preview.snapshot);
      expect(result.added, 1);

      final stored = (await target.listItems()).single;
      expect(stored.title, 'Isolate round trip');
      expect(stored.notes, 'Private note with a unicode marker.');
      expect(stored.rating, 4.5);

      final storedPhoto = await target.getAsset(stored.photoAssetIds.single);
      expect(storedPhoto, isNotNull);
      expect(storedPhoto!.bytes, photo.bytes);
      expect(sha256.convert(storedPhoto.bytes).toString(), photo.id);
    },
  );
}
