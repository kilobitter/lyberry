import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/data/sqlite_media_repository.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_support.dart';

/// The exact schema 1 shape, used to build a real legacy library file.
Future<void> createSchemaOne(Database db, int version) async {
  final batch = db.batch();
  batch.execute('''
    CREATE TABLE media_assets (
      id TEXT PRIMARY KEY NOT NULL,
      mime_type TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      width INTEGER NOT NULL,
      height INTEGER NOT NULL,
      data BLOB NOT NULL
    )
  ''');
  batch.execute('''
    CREATE TABLE media_items (
      id TEXT PRIMARY KEY NOT NULL,
      medium TEXT NOT NULL,
      title TEXT NOT NULL,
      creator TEXT NOT NULL,
      publisher TEXT NOT NULL,
      description TEXT NOT NULL,
      platform TEXT NOT NULL,
      year INTEGER,
      barcode TEXT,
      rating REAL,
      review TEXT NOT NULL,
      notes TEXT NOT NULL,
      cover_asset_id TEXT REFERENCES media_assets (id),
      photo_asset_ids TEXT NOT NULL,
      source_provider_id TEXT,
      source_external_id TEXT,
      source_url TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  batch.execute(
    'CREATE INDEX idx_media_items_created_at ON media_items (created_at DESC)',
  );
  batch.execute('CREATE INDEX idx_media_items_medium ON media_items (medium)');
  batch.execute(
    'CREATE INDEX idx_media_items_barcode ON media_items (barcode)',
  );
  await batch.commit(noResult: true);
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String databasePath;
  late SqliteMediaRepository repository;

  setUp(() async {
    directory = createTempDir('finished');
    databasePath = '${directory.path}/lyberry.db';
    repository = await openTestRepository(databasePath);
  });

  tearDown(() async {
    await repository.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'a new library stores false and keeps true across close and reopen',
    () async {
      const id = '00000000-0000-4000-8000-000000000101';
      await repository.createItem(
        sampleItem(id: id, medium: MediaType.book, isFinished: false),
      );

      var loaded = (await repository.getItem(id))!;
      expect(loaded.isFinished, isFalse);

      await repository.updateItem(
        loaded.copyWith(
          isFinished: true,
          updatedAt: '2026-09-23T11:00:00.000Z',
        ),
      );
      await repository.close();
      repository = await openTestRepository(databasePath);

      loaded = (await repository.getItem(id))!;
      expect(loaded.isFinished, isTrue);
      expect(loaded.updatedAt, '2026-09-23T11:00:00.000Z');
      expect(await repository.countItems(), 1);
    },
  );

  test('a populated schema 1 library upgrades in place', () async {
    final legacyPath = '${directory.path}/legacy.db';
    final cover = const ImageIngest().buildAsset(
      pngBytes(width: 12, height: 16),
    );
    final photo = const ImageIngest().buildAsset(
      jpegBytes(width: 20, height: 10),
    );

    await repository.close();
    final legacy = await databaseFactoryFfi.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(version: 1, onCreate: createSchemaOne),
    );
    await legacy.insert('media_assets', <String, Object?>{
      'id': cover.id,
      'mime_type': cover.mimeType,
      'byte_size': cover.byteSize,
      'width': cover.width,
      'height': cover.height,
      'data': cover.bytes,
    });
    await legacy.insert('media_assets', <String, Object?>{
      'id': photo.id,
      'mime_type': photo.mimeType,
      'byte_size': photo.byteSize,
      'width': photo.width,
      'height': photo.height,
      'data': photo.bytes,
    });
    const id = '00000000-0000-4000-8000-0000000001a1';
    await legacy.insert('media_items', <String, Object?>{
      'id': id,
      'medium': 'book',
      'title': 'Legacy Dune',
      'creator': 'Frank Herbert',
      'publisher': 'Chilton',
      'description': 'A legacy description.',
      'platform': '',
      'year': 1965,
      'barcode': '9780306406157',
      'rating': 4.5,
      'review': 'Legacy review.',
      'notes': 'Legacy notes.',
      'cover_asset_id': cover.id,
      'photo_asset_ids': '["${photo.id}"]',
      'source_provider_id': 'openlibrary',
      'source_external_id': 'OL123W',
      'source_url': 'https://openlibrary.org/works/OL123W',
      'created_at': '2026-01-02T03:04:05.000Z',
      'updated_at': '2026-01-03T03:04:05.000Z',
    });
    await legacy.close();

    repository = await openTestRepository(legacyPath);

    final loaded = (await repository.getItem(id))!;
    expect(await repository.countItems(), 1);
    expect(loaded.title, 'Legacy Dune');
    expect(loaded.creator, 'Frank Herbert');
    expect(loaded.publisher, 'Chilton');
    expect(loaded.description, 'A legacy description.');
    expect(loaded.year, 1965);
    expect(loaded.barcode, '9780306406157');
    expect(loaded.rating, 4.5);
    expect(loaded.review, 'Legacy review.');
    expect(loaded.notes, 'Legacy notes.');
    expect(loaded.coverAssetId, cover.id);
    expect(loaded.photoAssetIds, <String>[photo.id]);
    expect(loaded.source?.providerId, 'openlibrary');
    expect(loaded.source?.externalId, 'OL123W');
    expect(loaded.createdAt, '2026-01-02T03:04:05.000Z');
    expect(loaded.updatedAt, '2026-01-03T03:04:05.000Z');
    expect(loaded.isFinished, isFalse);

    final storedCover = (await repository.getAsset(cover.id))!;
    final storedPhoto = (await repository.getAsset(photo.id))!;
    expect(storedCover.bytes, cover.bytes);
    expect(storedCover.width, cover.width);
    expect(storedCover.height, cover.height);
    expect(storedPhoto.bytes, photo.bytes);

    // The upgrade must have happened in place, to schema 2 with the new column.
    await repository.close();
    final upgraded = await databaseFactoryFfi.openDatabase(legacyPath);
    expect(await upgraded.getVersion(), 2);
    final columns = await upgraded.rawQuery('PRAGMA table_info(media_items)');
    expect(
      columns.map((row) => row['name']).whereType<String>(),
      contains('is_finished'),
    );
    await upgraded.close();

    // A finished flag written after the upgrade is durable.
    repository = await openTestRepository(legacyPath);
    await repository.updateItem(loaded.copyWith(isFinished: true));
    await repository.close();
    repository = await openTestRepository(legacyPath);
    expect((await repository.getItem(id))!.isFinished, isTrue);
  });

  test(
    'a future schema version is refused and the file is left alone',
    () async {
      final futurePath = '${directory.path}/future.db';
      await repository.close();
      final future = await databaseFactoryFfi.openDatabase(
        futurePath,
        options: OpenDatabaseOptions(version: 99, onCreate: (db, _) async {}),
      );
      await future.close();

      await expectLater(
        openTestRepository(futurePath),
        throwsA(isA<StorageFailure>()),
      );

      final untouched = await databaseFactoryFfi.openDatabase(futurePath);
      expect(await untouched.getVersion(), 99);
      await untouched.close();
    },
  );

  test(
    'a real library round-trips the flag through export and merge',
    () async {
      const finishedId = '00000000-0000-4000-8000-0000000002f1';
      const unfinishedId = '00000000-0000-4000-8000-0000000002f2';
      await repository.createItem(
        sampleItem(
          id: finishedId,
          medium: MediaType.dvd,
          title: 'Blade Runner',
          isFinished: true,
        ),
      );
      await repository.createItem(
        sampleItem(
          id: unfinishedId,
          medium: MediaType.bluray,
          title: 'Arrival',
          isFinished: false,
        ),
      );

      final exported = await repository.exportSnapshot();
      MediaItem itemFor(String id) =>
          exported.items.firstWhere((item) => item.id == id);
      expect(itemFor(finishedId).isFinished, isTrue);
      expect(itemFor(unfinishedId).isFinished, isFalse);

      // Flip both flags exactly the way an incoming backup would, then merge it
      // through the real repository write path.
      final flipped = LibrarySnapshot(
        exportedAt: exported.exportedAt,
        items: <MediaItem>[
          for (final item in exported.items)
            item.copyWith(isFinished: !item.isFinished),
        ],
        assets: exported.assets,
      );
      final result = await repository.mergeSnapshot(flipped);
      expect(result.added, 0);
      expect(result.updated, 2);

      await repository.close();
      repository = await openTestRepository(databasePath);
      expect((await repository.getItem(finishedId))!.isFinished, isFalse);
      expect((await repository.getItem(unfinishedId))!.isFinished, isTrue);
    },
  );

  test('a duplicated finished copy starts unfinished and is durable', () async {
    const sourceId = '00000000-0000-4000-8000-0000000002f3';
    await repository.createItem(
      sampleItem(
        id: sourceId,
        medium: MediaType.book,
        title: 'Dune',
        isFinished: true,
      ),
    );

    final copy = await repository.createCopy(sourceId);
    expect(copy.isFinished, isFalse);

    await repository.close();
    repository = await openTestRepository(databasePath);
    expect((await repository.getItem(copy.id))!.isFinished, isFalse);
    expect((await repository.getItem(sourceId))!.isFinished, isTrue);
  });

  test('a claimed schema 2 file without the column is refused', () async {
    final brokenPath = '${directory.path}/claimed-v2.db';
    await repository.close();
    // The version marker says 2, but the table still has the schema 1 shape.
    final broken = await databaseFactoryFfi.openDatabase(
      brokenPath,
      options: OpenDatabaseOptions(version: 2, onCreate: createSchemaOne),
    );
    await broken.insert('media_items', <String, Object?>{
      'id': '00000000-0000-4000-8000-0000000002f4',
      'medium': 'book',
      'title': 'Claimed v2',
      'creator': '',
      'publisher': '',
      'description': '',
      'platform': '',
      'year': null,
      'barcode': null,
      'rating': null,
      'review': '',
      'notes': '',
      'cover_asset_id': null,
      'photo_asset_ids': '[]',
      'source_provider_id': null,
      'source_external_id': null,
      'source_url': null,
      'created_at': '2026-01-02T03:04:05.000Z',
      'updated_at': '2026-01-02T03:04:05.000Z',
    });
    await broken.close();

    await expectLater(
      openTestRepository(brokenPath),
      throwsA(isA<StorageFailure>()),
    );

    final untouched = await databaseFactoryFfi.openDatabase(brokenPath);
    expect(await untouched.getVersion(), 2);
    final columns = await untouched.rawQuery('PRAGMA table_info(media_items)');
    expect(
      columns.map((row) => row['name']).whereType<String>(),
      isNot(contains('is_finished')),
    );
    final rows = await untouched.query(
      'media_items',
      columns: <String>['id', 'title'],
    );
    expect(rows, hasLength(1));
    expect(rows.single['title'], 'Claimed v2');
    await untouched.close();
  });
}
