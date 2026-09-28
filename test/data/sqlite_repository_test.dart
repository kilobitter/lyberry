import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/data/database_location.dart';
import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/data/sqlite_media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_support.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String databasePath;
  late SqliteMediaRepository repository;

  setUp(() async {
    directory = createTempDir('repository');
    databasePath = '${directory.path}/lyberry.db';
    repository = await openTestRepository(databasePath);
  });

  tearDown(() async {
    await repository.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'persists full metadata and photo bytes across close and reopen',
    () async {
      final cover = const ImageIngest().buildAsset(
        pngBytes(width: 18, height: 24),
      );
      final photo = const ImageIngest().buildAsset(
        jpegBytes(width: 30, height: 20),
      );
      final item = sampleItem(
        id: '00000000-0000-4000-8000-000000000101',
        medium: MediaType.bluray,
        title: 'Blade Runner 2049',
        creator: 'Denis Villeneuve',
        publisher: 'Warner Bros.',
        description: 'A replicant hunt in a flooded Los Angeles.',
        year: 2017,
        barcode: '5051892202657',
        rating: 4.5,
        review: 'Still the reference disc.',
        notes: 'Signed slipcase.',
        coverAssetId: cover.id,
        photoAssetIds: <String>[photo.id],
      );

      await repository.createItem(item, assets: <MediaAsset>[cover, photo]);
      expect(await repository.countItems(), 1);

      await repository.close();
      repository = await openTestRepository(
        databasePath,
        clock: FixedClock(kBaseTime),
      );

      final stored = await repository.getItem(item.id);
      expect(stored, isNotNull);
      expect(stored!.title, 'Blade Runner 2049');
      expect(stored.medium, MediaType.bluray);
      expect(stored.year, 2017);
      expect(stored.rating, 4.5);
      expect(stored.review, 'Still the reference disc.');
      expect(stored.notes, 'Signed slipcase.');
      expect(stored.barcode, '5051892202657');
      expect(stored.coverAssetId, cover.id);
      expect(stored.photoAssetIds, <String>[photo.id]);

      final storedCover = await repository.getAsset(cover.id);
      final storedPhoto = await repository.getAsset(photo.id);
      expect(storedCover?.bytes, cover.bytes);
      expect(storedCover?.mimeType, AssetMime.png);
      expect(storedCover?.width, 18);
      expect(storedCover?.height, 24);
      expect(storedPhoto?.bytes, photo.bytes);
      expect(storedPhoto?.mimeType, AssetMime.jpeg);
    },
  );

  test('keeps two owned copies that share a barcode', () async {
    final first = sampleItem(
      id: '00000000-0000-4000-8000-000000000201',
      title: 'Dune',
      barcode: '9780306406157',
      createdAt: '2026-09-23T10:00:00.000Z',
      updatedAt: '2026-09-23T10:00:00.000Z',
    );
    final second = sampleItem(
      id: '00000000-0000-4000-8000-000000000202',
      title: 'Dune (second copy)',
      barcode: '9780306406157',
      rating: 3.0,
      createdAt: '2026-09-23T11:00:00.000Z',
      updatedAt: '2026-09-23T11:00:00.000Z',
    );

    await repository.createItem(first);
    await repository.createItem(second);

    final items = await repository.listItems();
    expect(items, hasLength(2));
    expect(items.map((item) => item.id).toSet(), <String>{first.id, second.id});
    expect(items.first.id, second.id, reason: 'newest first');
  });

  test(
    'createCopy keeps metadata, clears personal data and leaves the source',
    () async {
      final cover = const ImageIngest().buildAsset(pngBytes());
      final photo = const ImageIngest().buildAsset(jpegBytes());
      final source = sampleItem(
        id: '00000000-0000-4000-8000-000000000301',
        medium: MediaType.vinyl,
        title: 'Mezzanine',
        creator: 'Massive Attack',
        year: 1998,
        barcode: '0724384654726',
        rating: 5.0,
        review: 'Desert island record.',
        notes: 'First pressing.',
        coverAssetId: cover.id,
        photoAssetIds: <String>[photo.id],
        source: const MediaSource(
          providerId: 'musicbrainz',
          externalId: 'release-1',
          url: 'https://musicbrainz.org/release/release-1',
        ),
      );
      await repository.createItem(source, assets: <MediaAsset>[cover, photo]);

      final copy = await repository.createCopy(source.id);

      expect(copy.id, isNot(source.id));
      expect(copy.medium, source.medium);
      expect(copy.title, source.title);
      expect(copy.creator, source.creator);
      expect(copy.year, source.year);
      expect(copy.barcode, source.barcode);
      expect(copy.coverAssetId, cover.id);

      expect(copy.rating, isNull);
      expect(copy.review, isEmpty);
      expect(copy.notes, isEmpty);
      expect(copy.photoAssetIds, isEmpty);

      final original = await repository.getItem(source.id);
      expect(original, source);
      expect(await repository.countItems(), 2);
    },
  );

  test(
    'searches titles, creators and barcodes and filters by medium',
    () async {
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000401',
          medium: MediaType.book,
          title: 'Dune',
          creator: 'Frank Herbert',
          barcode: '9780306406157',
          createdAt: '2026-09-23T10:00:00.000Z',
          updatedAt: '2026-09-23T10:00:00.000Z',
        ),
      );
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000402',
          medium: MediaType.game,
          title: "Mirror's Edge",
          creator: 'DICE',
          platform: 'PlayStation 3',
          year: 2008,
          createdAt: '2026-09-23T11:00:00.000Z',
          updatedAt: '2026-09-23T11:00:00.000Z',
        ),
      );
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000403',
          medium: MediaType.cd,
          title: 'Mezzanine',
          creator: 'Massive Attack',
          barcode: '0724384654726',
          createdAt: '2026-09-23T12:00:00.000Z',
          updatedAt: '2026-09-23T12:00:00.000Z',
        ),
      );

      expect(await repository.listItems(query: 'dune'), hasLength(1));
      expect(await repository.listItems(query: 'FRANK'), hasLength(1));
      expect(await repository.listItems(query: '0724384654726'), hasLength(1));
      expect(await repository.listItems(query: 'missing'), isEmpty);
      expect(await repository.listItems(medium: MediaType.game), hasLength(1));
      expect(
        (await repository.listItems(medium: MediaType.game)).single.title,
        "Mirror's Edge",
      );
      expect(await repository.listItems(medium: MediaType.vinyl), isEmpty);
      expect(await repository.countItems(), 3);
    },
  );

  test('percent and underscore in a query are matched literally', () async {
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000501',
        title: '100% Hits',
      ),
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000502',
        title: 'Other record',
      ),
    );
    expect(await repository.listItems(query: '100%'), hasLength(1));
    expect(await repository.listItems(query: '%'), hasLength(1));
  });

  test('delete removes only the targeted copy', () async {
    await repository.createItem(
      sampleItem(id: '00000000-0000-4000-8000-000000000601', title: 'Keep'),
    );
    await repository.createItem(
      sampleItem(id: '00000000-0000-4000-8000-000000000602', title: 'Remove'),
    );

    await repository.deleteItem('00000000-0000-4000-8000-000000000602');

    expect(await repository.countItems(), 1);
    expect(
      await repository.getItem('00000000-0000-4000-8000-000000000602'),
      isNull,
    );
    expect(
      () => repository.deleteItem('00000000-0000-4000-8000-000000000602'),
      throwsA(isA<ItemNotFoundFailure>()),
    );
  });

  test(
    'an item referencing a missing image is rejected without a partial write',
    () async {
      final item = sampleItem(
        id: '00000000-0000-4000-8000-000000000701',
        photoAssetIds: <String>['c' * 64],
      );

      await expectLater(
        repository.createItem(item),
        throwsA(isA<StorageFailure>()),
      );
      expect(await repository.countItems(), 0);
    },
  );

  test(
    'update replaces the row and keeps the identity and creation time',
    () async {
      final original = sampleItem(
        id: '00000000-0000-4000-8000-000000000801',
        title: 'Dune',
        rating: 3.0,
      );
      await repository.createItem(original);

      final updated = original.copyWith(
        rating: 4.5,
        review: 'Better on a second read.',
        updatedAt: '2026-09-24T09:00:00.000Z',
      );
      await repository.updateItem(updated);

      final stored = await repository.getItem(original.id);
      expect(stored, updated);
      expect(stored!.createdAt, original.createdAt);
      expect(await repository.countItems(), 1);
    },
  );

  test('update of a missing item fails loudly', () async {
    await expectLater(
      repository.updateItem(
        sampleItem(id: '00000000-0000-4000-8000-000000000901'),
      ),
      throwsA(isA<ItemNotFoundFailure>()),
    );
  });

  test('export then merge preserves ids, assets and separate copies', () async {
    final cover = const ImageIngest().buildAsset(
      pngBytes(width: 16, height: 16),
    );
    final original = sampleItem(
      id: '00000000-0000-4000-8000-000000000a01',
      title: 'Dune',
      barcode: '9780306406157',
      rating: 4.0,
      review: 'First pass.',
      coverAssetId: cover.id,
    );
    await repository.createItem(original, assets: <MediaAsset>[cover]);
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000a02',
        title: 'Local only',
      ),
    );

    final snapshot = await repository.exportSnapshot();
    final encoded = SnapshotCodec.encode(snapshot);
    final decoded = SnapshotCodec.decode(encoded);
    expect(decoded.items, hasLength(2));
    expect(decoded.assets.single.bytes, cover.bytes);

    final targetDirectory = createTempDir('merge_target');
    final target = await openTestRepository(
      '${targetDirectory.path}/lyberry.db',
    );
    addTearDown(() async {
      await target.close();
      if (targetDirectory.existsSync()) {
        targetDirectory.deleteSync(recursive: true);
      }
    });

    final first = await target.mergeSnapshot(decoded);
    expect(first.added, 2);
    expect(first.updated, 0);
    expect(first.assetsAdded, 1);

    final second = await target.mergeSnapshot(decoded);
    expect(second.added, 0);
    expect(second.updated, 2);
    expect(second.assetsAdded, 0, reason: 'asset blobs are content addressed');

    final merged = await target.getItem(original.id);
    expect(merged, original);
    expect(await target.countItems(), 2);
  });

  test('a local item missing from the snapshot stays untouched', () async {
    final kept = sampleItem(
      id: '00000000-0000-4000-8000-000000000b01',
      title: 'Kept locally',
    );
    await repository.createItem(kept);
    final incoming = sampleItem(
      id: '00000000-0000-4000-8000-000000000b02',
      title: 'Incoming',
      barcode: '9780306406157',
    );

    final result = await repository.mergeSnapshot(
      LibrarySnapshot(
        exportedAt: kBaseTimestamp,
        items: <MediaItem>[
          incoming,
          sampleItem(
            id: '00000000-0000-4000-8000-000000000b03',
            title: 'Different copy, same barcode',
            barcode: '9780306406157',
          ),
        ],
        assets: const <MediaAsset>[],
      ),
    );

    expect(result.added, 2);
    expect(await repository.getItem(kept.id), kept);
    expect(await repository.countItems(), 3);
  });

  test(
    'merge rolls back every row when one incoming item is invalid',
    () async {
      final snapshot = LibrarySnapshot(
        exportedAt: kBaseTimestamp,
        items: <MediaItem>[
          sampleItem(
            id: '00000000-0000-4000-8000-000000000c01',
            title: 'Valid',
          ),
          sampleItem(
            id: '00000000-0000-4000-8000-000000000c02',
            title: 'Invalid rating',
            rating: 4.25,
          ),
        ],
        assets: const <MediaAsset>[],
      );

      await expectLater(
        repository.mergeSnapshot(snapshot),
        throwsA(isA<ValidationException>()),
      );
      expect(await repository.countItems(), 0);
    },
  );

  test(
    'a file that is not a library fails loudly and is left in place',
    () async {
      final brokenPath = '${directory.path}/broken.db';
      final file = File(brokenPath)
        ..writeAsStringSync('this is not a database');
      final broken = SqliteMediaRepository(
        factory: databaseFactoryFfi,
        location: FixedDatabaseLocation(brokenPath),
      );

      await expectLater(broken.initialize(), throwsA(isA<StorageFailure>()));
      expect(file.readAsStringSync(), 'this is not a database');
      await broken.close();
    },
  );

  test('a forged asset id is rejected without touching the library', () async {
    final real = const ImageIngest().buildAsset(
      pngBytes(width: 10, height: 10),
    );
    final forged = MediaAsset(
      id: '0' * 64,
      mimeType: real.mimeType,
      bytes: real.bytes,
      width: real.width,
      height: real.height,
    );
    final item = sampleItem(
      id: '00000000-0000-4000-8000-000000000d01',
      photoAssetIds: <String>[forged.id],
    );

    await expectLater(
      repository.createItem(item, assets: <MediaAsset>[forged]),
      throwsA(isA<ValidationException>()),
    );
    expect(await repository.countItems(), 0);
    expect(await repository.getAsset(forged.id), isNull);
  });

  test('asset metadata that disagrees with its bytes is rejected', () async {
    final real = const ImageIngest().buildAsset(
      pngBytes(width: 10, height: 10),
    );

    final lyingMime = MediaAsset(
      id: real.id,
      mimeType: 'image/jpeg',
      bytes: real.bytes,
      width: real.width,
      height: real.height,
    );
    final lyingSize = MediaAsset(
      id: real.id,
      mimeType: real.mimeType,
      bytes: real.bytes,
      width: 1234,
      height: 1234,
    );

    for (final asset in <MediaAsset>[lyingMime, lyingSize]) {
      await expectLater(
        repository.createItem(
          sampleItem(
            id: '00000000-0000-4000-8000-000000000d02',
            photoAssetIds: <String>[asset.id],
          ),
          assets: <MediaAsset>[asset],
        ),
        throwsA(isA<ValidationException>()),
      );
    }
    expect(await repository.countItems(), 0);
    expect(await repository.getAsset(real.id), isNull);
  });

  test(
    'merge counts inserted assets, not row ids, and stays idempotent',
    () async {
      final first = const ImageIngest().buildAsset(
        pngBytes(width: 11, height: 11),
      );
      final second = const ImageIngest().buildAsset(
        jpegBytes(width: 12, height: 12),
      );
      final snapshot = LibrarySnapshot(
        exportedAt: kBaseTimestamp,
        items: <MediaItem>[
          sampleItem(
            id: '00000000-0000-4000-8000-000000000e01',
            title: 'With two images',
            coverAssetId: first.id,
            photoAssetIds: <String>[second.id],
          ),
        ],
        assets: <MediaAsset>[first, second],
      );

      final firstMerge = await repository.mergeSnapshot(snapshot);
      expect(firstMerge.added, 1);
      expect(firstMerge.assetsAdded, 2);

      final secondMerge = await repository.mergeSnapshot(snapshot);
      expect(secondMerge.updated, 1);
      expect(secondMerge.assetsAdded, 0);
      expect(await repository.countItems(), 1);
    },
  );

  test('merge rolls back when an incoming asset is forged', () async {
    final real = const ImageIngest().buildAsset(pngBytes(width: 9, height: 9));
    final forged = MediaAsset(
      id: 'f' * 64,
      mimeType: real.mimeType,
      bytes: real.bytes,
      width: real.width,
      height: real.height,
    );
    final snapshot = LibrarySnapshot(
      exportedAt: kBaseTimestamp,
      items: <MediaItem>[
        sampleItem(
          id: '00000000-0000-4000-8000-000000000f01',
          title: 'Should not land',
          coverAssetId: forged.id,
        ),
      ],
      assets: <MediaAsset>[forged],
    );

    await expectLater(
      repository.mergeSnapshot(snapshot),
      throwsA(isA<ValidationException>()),
    );
    expect(await repository.countItems(), 0);
    expect(await repository.getAsset(forged.id), isNull);
  });
}
