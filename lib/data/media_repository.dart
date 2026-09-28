import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';

/// Storage failure that the UI should show as a recoverable error.
class StorageFailure implements Exception {
  const StorageFailure(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'StorageFailure: $message${cause == null ? '' : ' ($cause)'}';
}

/// Raised when an item id does not exist.
class ItemNotFoundFailure implements Exception {
  const ItemNotFoundFailure(this.id);

  final String id;

  @override
  String toString() => 'ItemNotFoundFailure: $id';
}

/// The library store the UI talks to.
///
/// All methods are async and every multi-row change is atomic. Implementations
/// must never silently fall back to an empty store when the real one fails.
abstract interface class MediaRepository {
  /// Opens the durable store. Safe to call more than once.
  Future<void> initialize();

  /// Newest first. [query] matches title, creator, publisher, description,
  /// review, notes and barcode.
  Future<List<MediaItem>> listItems({MediaType? medium, String? query});

  /// Number of owned copies, ignoring any filter.
  Future<int> countItems();

  /// Identities only, for merge previews on large libraries.
  Future<Set<String>> existingItemIds();

  Future<MediaItem?> getItem(String id);

  Future<MediaAsset?> getAsset(String id);

  /// Inserts the item and any new assets in one transaction.
  Future<void> createItem(MediaItem item, {List<MediaAsset> assets = const []});

  /// Replaces the item row and stores any new assets in one transaction.
  Future<void> updateItem(MediaItem item, {List<MediaAsset> assets = const []});

  /// Duplicates metadata and cover art, clears personal fields, assigns a new id.
  Future<MediaItem> createCopy(String sourceItemId);

  Future<void> deleteItem(String id);

  /// Everything needed to rebuild this library on another device.
  Future<LibrarySnapshot> exportSnapshot();

  /// Applies a snapshot in one transaction: incoming items win, matched by id.
  Future<MergeResult> mergeSnapshot(LibrarySnapshot snapshot);

  Future<void> close();
}
