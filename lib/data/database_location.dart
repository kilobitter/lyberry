import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

/// Resolves where the library file lives, so tests can point at a temp folder.
abstract interface class DatabaseLocation {
  Future<String> resolve();
}

class DefaultDatabaseLocation implements DatabaseLocation {
  const DefaultDatabaseLocation({this.fileName = 'lyberry.db'});

  final String fileName;

  @override
  Future<String> resolve() async {
    final directory = await sqflite.getDatabasesPath();
    return p.join(directory, fileName);
  }
}

class FixedDatabaseLocation implements DatabaseLocation {
  const FixedDatabaseLocation(this.path);

  final String path;

  @override
  Future<String> resolve() async => path;
}
