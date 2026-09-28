import 'package:uuid/uuid.dart';

/// Injectable UUID source so tests can produce deterministic identities.
abstract interface class IdGenerator {
  String newId();
}

class UuidV4IdGenerator implements IdGenerator {
  UuidV4IdGenerator([Uuid? uuid]) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  @override
  String newId() => _uuid.v4();
}

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

bool isUuidV4(String value) => _uuidV4Pattern.hasMatch(value);

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

bool isSha256Hex(String value) => _sha256Pattern.hasMatch(value);
