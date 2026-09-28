import 'package:sqflite_common/sqlite_api.dart';

/// Raised when the file on disk is not a Lyberry database this build can use.
///
/// The app surfaces this as a recoverable error; it never deletes or replaces
/// the user's file.
class DatabaseSchemaException implements Exception {
  const DatabaseSchemaException(this.message);

  final String message;

  @override
  String toString() => 'DatabaseSchemaException: $message';
}

/// Opens and verifies the durable SQLite store.
abstract final class LyberryDatabase {
  static const String itemsTable = 'media_items';
  static const String assetsTable = 'media_assets';

  /// Schema 2 adds the additive `is_finished` column (books and films).
  static const int schemaVersion = 2;

  /// The only schema this build can upgrade from, in place and transactionally.
  static const int _oldestSupportedVersion = 1;

  static Future<Database> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final database = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => _createSchema(db),
        onUpgrade: _upgrade,
        onDowngrade: _downgrade,
      ),
    );
    try {
      await _verifySchema(database);
    } on Object {
      await database.close();
      rethrow;
    }
    return database;
  }

  static Future<void> _createSchema(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE $assetsTable (
        id TEXT PRIMARY KEY NOT NULL,
        mime_type TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        data BLOB NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE $itemsTable (
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
        is_finished INTEGER NOT NULL DEFAULT 0 CHECK (is_finished IN (0, 1)),
        cover_asset_id TEXT REFERENCES $assetsTable (id),
        photo_asset_ids TEXT NOT NULL,
        source_provider_id TEXT,
        source_external_id TEXT,
        source_url TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_media_items_created_at ON $itemsTable (created_at DESC)',
    );
    batch.execute(
      'CREATE INDEX idx_media_items_medium ON $itemsTable (medium)',
    );
    batch.execute(
      'CREATE INDEX idx_media_items_barcode ON $itemsTable (barcode)',
    );
    await batch.commit(noResult: true);
  }

  static Future<void> _upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion == _oldestSupportedVersion && newVersion == schemaVersion) {
      // Additive upgrade only: every existing row keeps its data, and the new
      // column defaults to "not finished". The library is never recreated.
      await db.execute(
        'ALTER TABLE $itemsTable ADD COLUMN is_finished INTEGER NOT NULL '
        'DEFAULT 0 CHECK (is_finished IN (0, 1))',
      );
      return;
    }
    throw DatabaseSchemaException(
      'Cannot upgrade the library from schema $oldVersion to $newVersion.',
    );
  }

  static Future<void> _downgrade(Database db, int oldVersion, int newVersion) {
    throw DatabaseSchemaException(
      'This library was written by a newer version of Lyberry '
      '(schema $oldVersion). Update the app instead of replacing the file.',
    );
  }

  static Future<void> _verifySchema(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)",
      <Object?>[itemsTable, assetsTable],
    );
    final found = rows.map((row) => row['name']).whereType<String>().toSet();
    if (!found.contains(itemsTable) || !found.contains(assetsTable)) {
      throw const DatabaseSchemaException(
        'This file is not a Lyberry library (expected tables are missing).',
      );
    }
    // A file that claims the current schema must really carry the finished
    // column; otherwise the in-place upgrade did not complete.
    final version = await db.getVersion();
    if (version == schemaVersion) {
      final columns = await db.rawQuery('PRAGMA table_info($itemsTable)');
      final names = columns
          .map((row) => row['name'])
          .whereType<String>()
          .toSet();
      if (!names.contains('is_finished')) {
        throw const DatabaseSchemaException(
          'This library is missing the finished column '
          '(expected schema $schemaVersion).',
        );
      }
    }
  }
}
