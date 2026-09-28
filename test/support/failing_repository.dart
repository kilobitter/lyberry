import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';

/// Storage stub that fails to open until [fail] is cleared, so the UI error
/// and retry paths can be exercised without a broken real file.
class FailingRepository implements MediaRepository {
  FailingRepository({this.fail = true});

  bool fail;
  int initializeCalls = 0;
  final List<MediaItem> items = <MediaItem>[];

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (fail) {
      throw const StorageFailure(
        'Lyberry could not open your library at /tmp/lyberry.db.',
      );
    }
  }

  @override
  Future<List<MediaItem>> listItems({MediaType? medium, String? query}) async =>
      items;

  @override
  Future<int> countItems() async => items.length;

  @override
  Future<Set<String>> existingItemIds() async => <String>{
    for (final item in items) item.id,
  };

  @override
  Future<MediaItem?> getItem(String id) async => null;

  @override
  Future<MediaAsset?> getAsset(String id) async => null;

  @override
  Future<void> createItem(
    MediaItem item, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async => items.add(item);

  @override
  Future<void> updateItem(
    MediaItem item, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async {}

  @override
  Future<MediaItem> createCopy(String sourceItemId) async =>
      throw const ItemNotFoundFailure('sourceItemId');

  @override
  Future<void> deleteItem(String id) async {}

  @override
  Future<LibrarySnapshot> exportSnapshot() async => LibrarySnapshot(
    exportedAt: '2026-09-23T10:00:00.000Z',
    items: <MediaItem>[],
    assets: <MediaAsset>[],
  );

  @override
  Future<MergeResult> mergeSnapshot(LibrarySnapshot snapshot) async =>
      const MergeResult(added: 0, updated: 0, assetsAdded: 0);

  @override
  Future<void> close() async {}
}
