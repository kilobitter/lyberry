import 'dart:convert';
import 'dart:typed_data';

import 'package:lyberry/data/database.dart';
import 'package:lyberry/data/database_location.dart';
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
import 'package:sqflite_common/sqlite_api.dart';

/// Durable SQLite implementation of [MediaRepository].
///
/// Unreferenced asset rows are retained on purpose: deleting blobs is not
/// needed for v1 and keeping them removes any chance of deleting bytes that a
/// future merge still references.
class SqliteMediaRepository implements MediaRepository {
  SqliteMediaRepository({
    required DatabaseFactory factory,
    required DatabaseLocation location,
    IdGenerator? idGenerator,
    Clock? clock,
  }) : _factory = factory,
       _location = location,
       _idGenerator = idGenerator ?? UuidV4IdGenerator(),
       _clock = clock ?? const SystemClock();

  final DatabaseFactory _factory;
  final DatabaseLocation _location;
  final IdGenerator _idGenerator;
  final Clock _clock;

  /// Bounded slice size for reading image payloads out of SQLite.
  static const int _assetSliceBytes = 256 * 1024;

  Database? _database;

  @override
  Future<void> initialize() async {
    if (_database != null) return;
    final path = await _location.resolve();
    try {
      _database = await LyberryDatabase.open(factory: _factory, path: path);
    } on DatabaseException catch (error) {
      throw StorageFailure(
        'Lyberry could not open your library at $path.',
        error,
      );
    } on DatabaseSchemaException catch (error) {
      throw StorageFailure(error.message, error);
    }
  }

  Database get _db {
    final database = _database;
    if (database == null) {
      throw const StorageFailure('The library is not open yet.');
    }
    return database;
  }

  @override
  Future<List<MediaItem>> listItems({MediaType? medium, String? query}) async {
    final clauses = <String>[];
    final arguments = <Object?>[];

    if (medium != null) {
      clauses.add('medium = ?');
      arguments.add(medium.wireValue);
    }
    final search = query?.trim() ?? '';
    if (search.isNotEmpty) {
      final pattern = '%${_escapeLike(search.toLowerCase())}%';
      final expressions = [
        for (final column in _searchableColumns)
          "lower($column) LIKE ? ESCAPE '\\'",
        "lower(ifnull(barcode, '')) LIKE ? ESCAPE '\\'",
      ];
      clauses.add('(${expressions.join(' OR ')})');
      arguments.addAll(List<Object?>.filled(expressions.length, pattern));
    }

    final rows = await _db.query(
      LyberryDatabase.itemsTable,
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: arguments.isEmpty ? null : arguments,
      orderBy: 'created_at DESC, id ASC',
    );
    return rows.map(_itemFromRow).toList(growable: false);
  }

  @override
  Future<int> countItems() async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS total FROM ${LyberryDatabase.itemsTable}',
    );
    final value = rows.first['total'];
    return value is int ? value : 0;
  }

  @override
  Future<MediaItem?> getItem(String id) async {
    final rows = await _db.query(
      LyberryDatabase.itemsTable,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _itemFromRow(rows.first);
  }

  @override
  Future<MediaAsset?> getAsset(String id) async {
    return _readAsset(_db, id);
  }

  @override
  Future<Set<String>> existingItemIds() async {
    final rows = await _db.query(
      LyberryDatabase.itemsTable,
      columns: <String>['id'],
    );
    return <String>{
      for (final row in rows)
        if (row['id'] case final String id) id,
    };
  }

  /// Reads one asset without ever putting the whole BLOB in a cursor window.
  ///
  /// Android cursors have a bounded window, so metadata is read first and the
  /// payload is reconstructed from bounded `substr` slices.
  Future<MediaAsset?> _readAsset(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      LyberryDatabase.assetsTable,
      columns: <String>['id', 'mime_type', 'byte_size', 'width', 'height'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final byteSize = (row['byte_size']! as num).toInt();
    if (byteSize < 0 || byteSize > FieldLimits.maxAssetBytes) {
      throw StorageFailure(
        'Stored image $id has an impossible size ($byteSize bytes).',
      );
    }

    final builder = BytesBuilder(copy: false);
    var offset = 1; // SQLite substr() is 1-based.
    var remaining = byteSize;
    while (remaining > 0) {
      final take = remaining < _assetSliceBytes ? remaining : _assetSliceBytes;
      final sliceRows = await db.rawQuery(
        'SELECT substr(data, ?, ?) AS slice FROM '
        '${LyberryDatabase.assetsTable} WHERE id = ?',
        <Object?>[offset, take, id],
      );
      final slice = sliceRows.isEmpty ? null : sliceRows.first['slice'];
      if (slice is! List<int> || slice.isEmpty) {
        throw StorageFailure('Stored image $id is incomplete.');
      }
      builder.add(slice);
      offset += slice.length;
      remaining -= slice.length;
    }

    // Bytes read back from our own library: the raw constructor is correct here,
    // because browsing must not decode every stored raster again. Anything that
    // is not marked verified by MediaAsset.fromBytes is still fully checked when
    // it is written.
    return MediaAsset(
      id: row['id']! as String,
      mimeType: row['mime_type']! as String,
      bytes: builder.takeBytes(),
      width: (row['width']! as num).toInt(),
      height: (row['height']! as num).toInt(),
    );
  }

  @override
  Future<void> createItem(
    MediaItem item, {
    List<MediaAsset> assets = const [],
  }) async {
    _validateWrite(item);
    await _db.transaction((txn) async {
      await _insertAssets(txn, assets);
      await _assertAssetsPresent(txn, item);
      await txn.insert(
        LyberryDatabase.itemsTable,
        _rowFromItem(item),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    });
  }

  @override
  Future<void> updateItem(
    MediaItem item, {
    List<MediaAsset> assets = const [],
  }) async {
    _validateWrite(item);
    await _db.transaction((txn) async {
      await _insertAssets(txn, assets);
      await _assertAssetsPresent(txn, item);
      final updated = await txn.update(
        LyberryDatabase.itemsTable,
        _rowFromItem(item),
        where: 'id = ?',
        whereArgs: <Object?>[item.id],
      );
      if (updated == 0) {
        throw ItemNotFoundFailure(item.id);
      }
    });
  }

  @override
  Future<MediaItem> createCopy(String sourceItemId) async {
    final source = await getItem(sourceItemId);
    if (source == null) {
      throw ItemNotFoundFailure(sourceItemId);
    }
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
      rating: null,
      review: '',
      notes: '',
      // A new copy starts its own personal data, including the finished flag.
      isFinished: false,
      coverAssetId: source.coverAssetId,
      photoAssetIds: const <String>[],
      source: source.source,
      createdAt: now,
      updatedAt: now,
    );
    await _db.transaction((txn) async {
      await _assertAssetsPresent(txn, copy);
      await txn.insert(
        LyberryDatabase.itemsTable,
        _rowFromItem(copy),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    });
    return copy;
  }

  @override
  Future<void> deleteItem(String id) async {
    final deleted = await _db.delete(
      LyberryDatabase.itemsTable,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    if (deleted == 0) {
      throw ItemNotFoundFailure(id);
    }
  }

  @override
  Future<LibrarySnapshot> exportSnapshot() async {
    // One read transaction keeps the export internally consistent, and every
    // bound is checked before the payload is built.
    LibrarySnapshot? snapshot;
    await _db.transaction((txn) async {
      final itemRows = await txn.query(
        LyberryDatabase.itemsTable,
        orderBy: 'created_at DESC, id ASC',
      );
      if (itemRows.length > SnapshotCodec.maxItems) {
        throw const ValidationException([
          ValidationIssue('items', 'A backup can hold at most 10000 copies.'),
        ]);
      }
      final items = itemRows.map(_itemFromRow).toList(growable: false);

      final referenced = <String>{};
      for (final item in items) {
        if (item.coverAssetId != null) referenced.add(item.coverAssetId!);
        referenced.addAll(item.photoAssetIds);
      }

      final assets = <MediaAsset>[];
      var combined = 0;
      for (final id in referenced) {
        final asset = await _readAsset(txn, id);
        if (asset == null) continue;
        if (asset.byteSize > SnapshotCodec.maxAssetBytes) {
          throw ValidationException([
            ValidationIssue(
              'assets',
              'Image ${asset.id} is larger than the 5 MiB export limit.',
            ),
          ]);
        }
        combined += asset.byteSize;
        if (combined > SnapshotCodec.maxCombinedAssetBytes) {
          throw const ValidationException([
            ValidationIssue(
              'assets',
              'Image payload exceeds the 60 MiB export limit.',
            ),
          ]);
        }
        assets.add(asset);
      }

      snapshot = LibrarySnapshot(
        exportedAt: encodeTimestamp(_clock.nowUtc()),
        items: items,
        assets: assets,
      );
    });
    return snapshot!;
  }

  @override
  Future<MergeResult> mergeSnapshot(LibrarySnapshot snapshot) async {
    var added = 0;
    var updated = 0;
    var assetsAdded = 0;

    await _db.transaction((txn) async {
      for (final asset in snapshot.assets) {
        final existing = await txn.query(
          LyberryDatabase.assetsTable,
          columns: <String>['id'],
          where: 'id = ?',
          whereArgs: <Object?>[asset.id],
          limit: 1,
        );
        if (existing.isNotEmpty) continue;
        // Only genuinely new image bytes need to prove themselves; an id that
        // is already stored was verified when it was first written.
        _assertAssetMatchesBytes(asset);
        await txn.insert(
          LyberryDatabase.assetsTable,
          _rowFromAsset(asset),
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        assetsAdded++;
      }
      for (final item in snapshot.items) {
        ItemValidator.assertValid(item);
        await _assertAssetsPresent(txn, item);
        final existing = await txn.query(
          LyberryDatabase.itemsTable,
          columns: <String>['id'],
          where: 'id = ?',
          whereArgs: <Object?>[item.id],
          limit: 1,
        );
        await txn.insert(
          LyberryDatabase.itemsTable,
          _rowFromItem(item),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (existing.isEmpty) {
          added++;
        } else {
          updated++;
        }
      }
    });

    return MergeResult(
      added: added,
      updated: updated,
      assetsAdded: assetsAdded,
    );
  }

  @override
  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
  }

  void _validateWrite(MediaItem item) {
    ItemValidator.assertValid(item);
  }

  /// A stored asset must be the image its id and metadata claim to be, so a
  /// forged or stale asset cannot poison the content-addressed store.
  void _assertAssetMatchesBytes(MediaAsset asset) {
    final issues = <ValidationIssue>[...ItemValidator.validateAsset(asset)];
    // Decoding every imported raster again on the UI isolate is expensive; an
    // asset that a trusted path already verified only needs the cheap checks.
    if (!asset.contentVerified) {
      issues.addAll(ImageInspector.verifyAsset(asset));
    }
    if (issues.isNotEmpty) throw ValidationException(issues);
  }

  Future<void> _insertAssets(
    DatabaseExecutor txn,
    List<MediaAsset> assets,
  ) async {
    for (final asset in assets) {
      final existing = await txn.query(
        LyberryDatabase.assetsTable,
        columns: <String>['id'],
        where: 'id = ?',
        whereArgs: <Object?>[asset.id],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      _assertAssetMatchesBytes(asset);
      await txn.insert(
        LyberryDatabase.assetsTable,
        _rowFromAsset(asset),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
  }

  /// Referential integrity is enforced here because SQLite cannot express it
  /// for the ordered photo id list.
  Future<void> _assertAssetsPresent(
    DatabaseExecutor txn,
    MediaItem item,
  ) async {
    final referenced = <String>[
      if (item.coverAssetId != null) item.coverAssetId!,
      ...item.photoAssetIds,
    ];
    for (final id in referenced) {
      final rows = await txn.query(
        LyberryDatabase.assetsTable,
        columns: <String>['id'],
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StorageFailure('Image $id is missing from the library.');
      }
    }
  }

  static MediaItem _itemFromRow(Map<String, Object?> row) {
    final rawPhotos = row['photo_asset_ids'];
    final photos = rawPhotos is String && rawPhotos.isNotEmpty
        ? (jsonDecode(rawPhotos) as List<Object?>).cast<String>()
        : const <String>[];
    final providerId = row['source_provider_id'] as String?;
    final externalId = row['source_external_id'] as String?;
    return MediaItem(
      id: row['id']! as String,
      medium: MediaType.parse(row['medium']),
      title: row['title']! as String,
      creator: row['creator']! as String,
      publisher: row['publisher']! as String,
      description: row['description']! as String,
      platform: row['platform']! as String,
      year: row['year'] as int?,
      barcode: row['barcode'] as String?,
      rating: (row['rating'] as num?)?.toDouble(),
      review: row['review']! as String,
      notes: row['notes']! as String,
      isFinished: (row['is_finished'] as int? ?? 0) == 1,
      coverAssetId: row['cover_asset_id'] as String?,
      photoAssetIds: photos,
      source: providerId == null || externalId == null
          ? null
          : MediaSource(
              providerId: providerId,
              externalId: externalId,
              url: (row['source_url'] as String?) ?? '',
            ),
      createdAt: row['created_at']! as String,
      updatedAt: row['updated_at']! as String,
    );
  }

  static Map<String, Object?> _rowFromItem(MediaItem item) => <String, Object?>{
    'id': item.id,
    'medium': item.medium.wireValue,
    'title': item.title,
    'creator': item.creator,
    'publisher': item.publisher,
    'description': item.description,
    'platform': item.platform,
    'year': item.year,
    'barcode': item.barcode,
    'rating': item.rating,
    'review': item.review,
    'notes': item.notes,
    'is_finished': item.isFinished ? 1 : 0,
    'cover_asset_id': item.coverAssetId,
    'photo_asset_ids': jsonEncode(item.photoAssetIds),
    'source_provider_id': item.source?.providerId,
    'source_external_id': item.source?.externalId,
    'source_url': item.source?.url,
    'created_at': item.createdAt,
    'updated_at': item.updatedAt,
  };

  static Map<String, Object?> _rowFromAsset(MediaAsset asset) =>
      <String, Object?>{
        'id': asset.id,
        'mime_type': asset.mimeType,
        'byte_size': asset.byteSize,
        'width': asset.width,
        'height': asset.height,
        'data': asset.bytes,
      };

  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  static const List<String> _searchableColumns = <String>[
    'title',
    'creator',
    'publisher',
    'description',
    'review',
    'notes',
  ];
}
