import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/ids.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/timestamps.dart';
import 'package:lyberry/domain/validation.dart';

/// In-memory store with the same observable rules as the SQLite repository:
/// newest-first ordering, the same searchable fields, content-addressed assets
/// and reference checking.
///
/// Widget and golden tests run under fake async, so they cannot await real
/// database I/O; the durable store is covered by the repository test suite.
class InMemoryMediaRepository implements MediaRepository {
  InMemoryMediaRepository({IdGenerator? idGenerator, Clock? clock})
    : _idGenerator = idGenerator ?? UuidV4IdGenerator(),
      _clock = clock ?? const SystemClock();

  final IdGenerator _idGenerator;
  final Clock _clock;

  final Map<String, MediaItem> _items = <String, MediaItem>{};
  final Map<String, MediaAsset> _assets = <String, MediaAsset>{};

  /// Optional artificial latency, used to exercise stale async reloads.
  Duration listItemsDelay = Duration.zero;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<MediaItem>> listItems({MediaType? medium, String? query}) async {
    if (listItemsDelay > Duration.zero) {
      await Future<void>.delayed(listItemsDelay);
    }
    final needle = query?.trim().toLowerCase() ?? '';
    final matches = _items.values.where((item) {
      if (medium != null && item.medium != medium) return false;
      if (needle.isEmpty) return true;
      return _haystack(item).contains(needle);
    }).toList();
    matches.sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });
    return matches;
  }

  String _haystack(MediaItem item) => <String>[
    item.title,
    item.creator,
    item.publisher,
    item.description,
    item.review,
    item.notes,
    item.barcode ?? '',
  ].join('\n').toLowerCase();

  @override
  Future<int> countItems() async => _items.length;

  @override
  Future<Set<String>> existingItemIds() async => _items.keys.toSet();

  @override
  Future<MediaItem?> getItem(String id) async => _items[id];

  @override
  Future<MediaAsset?> getAsset(String id) async => _assets[id];

  @override
  Future<void> createItem(
    MediaItem item, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async {
    ItemValidator.assertValid(item);
    _storeAssets(assets);
    _assertReferences(item);
    _items[item.id] = item;
  }

  @override
  Future<void> updateItem(
    MediaItem item, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async {
    ItemValidator.assertValid(item);
    if (!_items.containsKey(item.id)) throw ItemNotFoundFailure(item.id);
    _storeAssets(assets);
    _assertReferences(item);
    _items[item.id] = item;
  }

  @override
  Future<MediaItem> createCopy(String sourceItemId) async {
    final source = _items[sourceItemId];
    if (source == null) throw ItemNotFoundFailure(sourceItemId);
    final now = encodeTimestamp(_clock.nowUtc());
    final copy = MediaItem(
      id: _idGenerator.newId(),
      medium: source.medium,
      title: source.title,
      creator: source.creator,
      publisher: source.publisher,
      description: source.description,
      platform: source.platform,
      year: source.year,
      barcode: source.barcode,
      // A new copy starts its own personal data, including the finished flag.
      isFinished: false,
      coverAssetId: source.coverAssetId,
      source: source.source,
      createdAt: now,
      updatedAt: now,
    );
    _assertReferences(copy);
    _items[copy.id] = copy;
    return copy;
  }

  @override
  Future<void> deleteItem(String id) async {
    if (_items.remove(id) == null) throw ItemNotFoundFailure(id);
  }

  @override
  Future<LibrarySnapshot> exportSnapshot() async {
    final referenced = <String>{};
    for (final item in _items.values) {
      if (item.coverAssetId != null) referenced.add(item.coverAssetId!);
      referenced.addAll(item.photoAssetIds);
    }
    return LibrarySnapshot(
      exportedAt: encodeTimestamp(_clock.nowUtc()),
      items: _items.values.toList(),
      assets: <MediaAsset>[
        for (final id in referenced)
          if (_assets[id] != null) _assets[id]!,
      ],
    );
  }

  @override
  Future<MergeResult> mergeSnapshot(LibrarySnapshot snapshot) async {
    var added = 0;
    var updated = 0;
    var assetsAdded = 0;
    for (final asset in snapshot.assets) {
      final issues = ItemValidator.validateAsset(asset);
      if (issues.isNotEmpty) throw ValidationException(issues);
      if (_assets.containsKey(asset.id)) continue;
      _assets[asset.id] = asset;
      assetsAdded++;
    }
    for (final item in snapshot.items) {
      ItemValidator.assertValid(item);
      _assertReferences(item);
      if (_items.containsKey(item.id)) {
        updated++;
      } else {
        added++;
      }
      _items[item.id] = item;
    }
    return MergeResult(
      added: added,
      updated: updated,
      assetsAdded: assetsAdded,
    );
  }

  @override
  Future<void> close() async {}

  void _storeAssets(List<MediaAsset> assets) {
    for (final asset in assets) {
      final issues = <ValidationIssue>[...ItemValidator.validateAsset(asset)];
      if (!asset.contentVerified) {
        issues.addAll(ImageInspector.verifyAsset(asset));
      }
      if (issues.isNotEmpty) throw ValidationException(issues);
      _assets.putIfAbsent(asset.id, () => asset);
    }
  }

  void _assertReferences(MediaItem item) {
    final referenced = <String>[
      if (item.coverAssetId != null) item.coverAssetId!,
      ...item.photoAssetIds,
    ];
    for (final id in referenced) {
      if (!_assets.containsKey(id)) {
        throw StorageFailure('Image $id is missing from the library.');
      }
    }
  }
}
