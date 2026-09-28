import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/data/sqlite_media_repository.dart';
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/cover_renderer.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/photo_fixtures.dart';
import '../support/test_support.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String databasePath;
  late SqliteMediaRepository repository;

  setUp(() async {
    directory = createTempDir('photo_cover');
    databasePath = '${directory.path}/lyberry.db';
    repository = await openTestRepository(databasePath);
  });

  tearDown(() async {
    await repository.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// The original photo plus a derived cover, exactly as the editor produces
  /// them: two independent content-addressed assets.
  ({MediaAsset photo, MediaAsset cover}) pair({
    CoverCrop crop = const CoverCrop(
      left: 0.25,
      top: 0.25,
      width: 0.5,
      height: 0.5,
    ),
  }) {
    final photo = const ImageIngest().buildAsset(quadJpeg());
    final cover = MediaAsset.fromBytes(
      CoverRenderer.renderCover(source: photo.bytes, crop: crop),
    );
    return (photo: photo, cover: cover);
  }

  test(
    'a derived cover and its original photo survive close and reopen',
    () async {
      const id = '00000000-0000-4000-8000-0000000004a1';
      final assets = pair();
      await repository.createItem(
        sampleItem(
          id: id,
          medium: MediaType.book,
          title: 'Photo cover',
          coverAssetId: assets.cover.id,
          photoAssetIds: <String>[assets.photo.id],
        ),
        assets: <MediaAsset>[assets.photo, assets.cover],
      );

      await repository.close();
      repository = await openTestRepository(databasePath);

      final loaded = (await repository.getItem(id))!;
      expect(loaded.coverAssetId, assets.cover.id);
      expect(loaded.photoAssetIds, <String>[assets.photo.id]);
      expect(loaded.coverAssetId, isNot(assets.photo.id));

      final storedCover = (await repository.getAsset(assets.cover.id))!;
      final storedPhoto = (await repository.getAsset(assets.photo.id))!;
      expect(storedCover.bytes, assets.cover.bytes);
      expect(storedCover.mimeType, AssetMime.jpeg);
      expect(storedCover.width, assets.cover.width);
      expect(storedCover.height, assets.cover.height);
      expect(storedPhoto.bytes, assets.photo.bytes);
    },
  );

  test('a derived cover round-trips through export and merge', () async {
    const id = '00000000-0000-4000-8000-0000000004a2';
    final assets = pair(
      crop: const CoverCrop(left: 0.1, top: 0.1, width: 0.6, height: 0.6),
    );
    await repository.createItem(
      sampleItem(
        id: id,
        medium: MediaType.dvd,
        title: 'Exported cover',
        coverAssetId: assets.cover.id,
        photoAssetIds: <String>[assets.photo.id],
      ),
      assets: <MediaAsset>[assets.photo, assets.cover],
    );

    final exported = await repository.exportSnapshot();
    expect(exported.assets.length, 2);
    final second = Directory.systemTemp.createTempSync('lyberry_photo_cover_b');
    final target = await openTestRepository('${second.path}/lyberry.db');
    try {
      await target.mergeSnapshot(exported);

      final merged = (await target.getItem(id))!;
      expect(merged.coverAssetId, assets.cover.id);
      expect(merged.photoAssetIds, <String>[assets.photo.id]);
      final mergedCover = (await target.getAsset(assets.cover.id))!;
      final mergedPhoto = (await target.getAsset(assets.photo.id))!;
      expect(mergedCover.bytes, assets.cover.bytes);
      expect(mergedPhoto.bytes, assets.photo.bytes);
      expect(await target.countItems(), 1);
    } finally {
      await target.close();
      second.deleteSync(recursive: true);
    }
  });

  test(
    'a codec-encoded backup carries an EXIF original and its derived cover',
    () async {
      const id = '00000000-0000-4000-8000-0000000004a4';
      final photo = const ImageIngest().buildAsset(quadJpeg(orientation: 6));
      expect(
        photo.width,
        240,
        reason: 'the stored original keeps its header size',
      );
      expect(photo.height, 120);
      expect(exifOrientation(photo.bytes), 6);

      final cover = MediaAsset.fromBytes(
        CoverRenderer.renderCover(source: photo.bytes, crop: CoverCrop.full),
      );
      expect(
        cover.width,
        120,
        reason: 'the derived cover is the oriented frame',
      );
      expect(cover.height, 240);
      expect(exifOrientation(cover.bytes), isNull);

      await repository.createItem(
        sampleItem(
          id: id,
          medium: MediaType.book,
          title: 'EXIF cover',
          coverAssetId: cover.id,
          photoAssetIds: <String>[photo.id],
        ),
        assets: <MediaAsset>[photo, cover],
      );

      // The portable path: encode the real payload, then decode it back through
      // the import validation before touching a second database.
      final payload = SnapshotCodec.encode(await repository.exportSnapshot());
      final decoded = SnapshotCodec.decode(payload);
      final decodedItem = decoded.items.single;
      expect(decodedItem.coverAssetId, cover.id);
      expect(decodedItem.photoAssetIds, <String>[photo.id]);
      expect(
        decoded.assets.map((asset) => asset.id),
        containsAll(<String>[photo.id, cover.id]),
      );

      final second = Directory.systemTemp.createTempSync(
        'lyberry_photo_cover_c',
      );
      final target = await openTestRepository('${second.path}/lyberry.db');
      try {
        await target.mergeSnapshot(decoded);
        final merged = (await target.getItem(id))!;
        expect(merged.coverAssetId, cover.id);
        expect(merged.photoAssetIds, <String>[photo.id]);

        final mergedPhoto = (await target.getAsset(photo.id))!;
        final mergedCover = (await target.getAsset(cover.id))!;
        expect(mergedPhoto.bytes, photo.bytes);
        expect(mergedPhoto.width, 240, reason: 'the original stays raw');
        expect(exifOrientation(mergedPhoto.bytes), 6);
        expect(mergedCover.bytes, cover.bytes);
        expect(mergedCover.width, 120, reason: 'the cover stays oriented');
        expect(exifOrientation(mergedCover.bytes), isNull);
      } finally {
        await target.close();
        second.deleteSync(recursive: true);
      }

      // The source library keeps the pair across a reopen too.
      await repository.close();
      repository = await openTestRepository(databasePath);
      final reopened = (await repository.getItem(id))!;
      expect(reopened.coverAssetId, cover.id);
      expect(reopened.photoAssetIds, <String>[photo.id]);
      expect((await repository.getAsset(photo.id))!.width, 240);
      expect((await repository.getAsset(cover.id))!.width, 120);
    },
  );

  test(
    'dropping the photo reference leaves the derived cover stored',
    () async {
      const id = '00000000-0000-4000-8000-0000000004a3';
      final assets = pair();
      await repository.createItem(
        sampleItem(
          id: id,
          medium: MediaType.bluray,
          title: 'Detached photo',
          coverAssetId: assets.cover.id,
          photoAssetIds: <String>[assets.photo.id],
        ),
        assets: <MediaAsset>[assets.photo, assets.cover],
      );

      final stored = (await repository.getItem(id))!;
      await repository.updateItem(
        stored.copyWith(
          photoAssetIds: const <String>[],
          updatedAt: '2026-09-23T12:00:00.000Z',
        ),
      );

      await repository.close();
      repository = await openTestRepository(databasePath);

      final reloaded = (await repository.getItem(id))!;
      expect(reloaded.photoAssetIds, isEmpty);
      expect(reloaded.coverAssetId, assets.cover.id);
      expect(await repository.getAsset(assets.cover.id), isNotNull);
      expect(await repository.getAsset(assets.photo.id), isNotNull);

      final merged = LibrarySnapshot(
        exportedAt: '2026-09-23T12:30:00.000Z',
        items: <MediaItem>[reloaded],
        assets: <MediaAsset>[assets.cover],
      );
      await repository.mergeSnapshot(merged);
      expect((await repository.getItem(id))!.coverAssetId, assets.cover.id);
    },
  );
}
