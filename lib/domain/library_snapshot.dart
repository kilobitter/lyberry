import 'dart:convert';
import 'dart:typed_data';

import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/timestamps.dart';
import 'package:lyberry/domain/validation.dart';

/// Portable whole-library payload: the backup format.
class LibrarySnapshot {
  LibrarySnapshot({
    required this.exportedAt,
    required List<MediaItem> items,
    required List<MediaAsset> assets,
  }) : items = List<MediaItem>.unmodifiable(items),
       assets = List<MediaAsset>.unmodifiable(assets);

  static const String format = 'lyberry';

  /// The version this build writes. Bumping it keeps an older app from
  /// silently dropping the new personal field on import.
  static const int schemaVersion = 2;

  /// The oldest payload this build can still read: schema 1 predates
  /// `isFinished` and imports with the flag defaulted to false.
  static const int oldestReadableSchemaVersion = 1;
  static const String fileExtension = '.lyberry.json';

  final String exportedAt;
  final List<MediaItem> items;
  final List<MediaAsset> assets;

  Map<String, Object?> toJson() => <String, Object?>{
    'format': format,
    'schemaVersion': schemaVersion,
    'exportedAt': exportedAt,
    'items': items.map((item) => item.toJson()).toList(growable: false),
    'assets': assets.map((asset) => asset.toJson()).toList(growable: false),
  };
}

/// Outcome of an atomic merge, used for the import preview and result.
class MergeResult {
  const MergeResult({
    required this.added,
    required this.updated,
    required this.assetsAdded,
  });

  final int added;
  final int updated;
  final int assetsAdded;

  @override
  String toString() =>
      'MergeResult(added: $added, updated: $updated, assetsAdded: $assetsAdded)';
}

/// Encodes and decodes [LibrarySnapshot] payloads.
///
/// Untrusted files are treated as hostile: every cap is enforced before the
/// expensive work it guards (byte caps before base64 decoding, decoded sizes
/// before allocation, references before image decoding), the schema version and
/// timestamps must be exact, and a malformed optional block is an error rather
/// than a silent drop. Decoding is all-or-nothing: either a fully validated
/// snapshot is returned or a [ValidationException] lists every problem found.
abstract final class SnapshotCodec {
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const int maxItems = 10000;
  static const int maxAssets = 10000;
  static const int maxCombinedAssetBytes = 60 * 1024 * 1024;
  static const int maxAssetBytes = FieldLimits.maxAssetBytes;

  static final RegExp _base64Pattern = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

  static const SnapshotLimits defaultLimits = SnapshotLimits();

  /// UTF-8 byte length without allocating a copy of the payload.
  static int utf8ByteLength(String value, {int limit = maxFileBytes}) {
    var bytes = 0;
    for (final rune in value.runes) {
      if (rune <= 0x7F) {
        bytes += 1;
      } else if (rune <= 0x7FF) {
        bytes += 2;
      } else if (rune <= 0xFFFF) {
        bytes += 3;
      } else {
        bytes += 4;
      }
      if (bytes > limit) return bytes;
    }
    return bytes;
  }

  /// Exact UTF-8 byte length of [value].
  static int exactUtf8Length(String value) {
    var bytes = 0;
    for (final rune in value.runes) {
      bytes += rune <= 0x7F
          ? 1
          : rune <= 0x7FF
          ? 2
          : rune <= 0xFFFF
          ? 3
          : 4;
    }
    return bytes;
  }

  /// Decoded byte count of canonical base64, or `null` when the text is not
  /// canonical. Never allocates the decoded payload.
  static int? base64DecodedLength(String data) {
    if (data.isEmpty) return 0;
    if (data.length % 4 != 0) return null;
    if (!_base64Pattern.hasMatch(data)) return null;
    final padding = data.endsWith('==')
        ? 2
        : data.endsWith('=')
        ? 1
        : 0;
    return data.length ~/ 4 * 3 - padding;
  }

  /// Enforces the export-side bounds and produces the portable JSON text.
  static String encode(
    LibrarySnapshot snapshot, {
    SnapshotLimits limits = defaultLimits,
  }) {
    final issues = <ValidationIssue>[];
    if (snapshot.items.length > limits.maxItems) {
      issues.add(
        ValidationIssue(
          'items',
          'A backup can hold at most ${limits.maxItems} copies.',
        ),
      );
    }
    if (snapshot.assets.length > limits.maxAssets) {
      issues.add(
        ValidationIssue(
          'assets',
          'A backup can hold at most ${limits.maxAssets} images.',
        ),
      );
    }
    if (!isCanonicalTimestamp(snapshot.exportedAt)) {
      issues.add(
        const ValidationIssue(
          'exportedAt',
          'Export timestamp must be canonical UTC ISO-8601.',
        ),
      );
    }
    var combined = 0;
    for (final asset in snapshot.assets) {
      if (asset.byteSize > limits.maxAssetBytes) {
        issues.add(
          ValidationIssue(
            'assets',
            'Image ${asset.id} is larger than the '
                '${_describeBytes(limits.maxAssetBytes)} export limit.',
          ),
        );
      }
      combined += asset.byteSize;
    }
    if (combined > limits.maxCombinedAssetBytes) {
      issues.add(
        ValidationIssue(
          'assets',
          'Image payload exceeds the '
              '${_describeBytes(limits.maxCombinedAssetBytes)} export limit.',
        ),
      );
    }
    if (issues.isNotEmpty) throw ValidationException(issues);

    // Exact bounded encoding: every element is escaped by the real JSON encoder
    // and counted as it is appended, so an oversized payload is refused before
    // the whole string exists. Nothing is rejected on a rough estimate, and
    // control-character escaping and nested fields are counted exactly.
    const encoder = JsonEncoder();
    final buffer = StringBuffer();
    var bytes = 0;

    void add(String chunk) {
      bytes += exactUtf8Length(chunk);
      if (bytes > limits.maxFileBytes) {
        throw ValidationException([
          ValidationIssue(
            'file',
            'This backup would be larger than '
                '${_describeBytes(limits.maxFileBytes)}.',
          ),
        ]);
      }
      buffer.write(chunk);
    }

    add('{"format":"${LibrarySnapshot.format}","schemaVersion":');
    add('${LibrarySnapshot.schemaVersion}');
    add(',"exportedAt":');
    add(encoder.convert(snapshot.exportedAt));
    add(',"items":[');
    for (var index = 0; index < snapshot.items.length; index++) {
      if (index > 0) add(',');
      add(encoder.convert(snapshot.items[index].toJson()));
    }
    add('],"assets":[');
    for (var index = 0; index < snapshot.assets.length; index++) {
      if (index > 0) add(',');
      add(encoder.convert(snapshot.assets[index].toJson()));
    }
    add(']}');
    return buffer.toString();
  }

  static LibrarySnapshot decode(
    String source, {
    SnapshotLimits limits = defaultLimits,
  }) {
    if (utf8ByteLength(source, limit: limits.maxFileBytes) >
        limits.maxFileBytes) {
      throw ValidationException([
        ValidationIssue(
          'file',
          'Backups must be ${_describeBytes(limits.maxFileBytes)} or smaller.',
        ),
      ]);
    }
    final Object? raw;
    try {
      raw = jsonDecode(source);
    } on FormatException catch (error) {
      throw ValidationException([
        ValidationIssue('file', 'Not valid JSON: ${error.message}'),
      ]);
    }
    if (raw is! Map) {
      throw const ValidationException([
        ValidationIssue('file', 'Backup root must be a JSON object.'),
      ]);
    }
    return decodeMap(raw.cast<String, Object?>(), limits: limits);
  }

  static LibrarySnapshot decodeMap(
    Map<String, Object?> json, {
    SnapshotLimits limits = defaultLimits,
  }) {
    final issues = <ValidationIssue>[];

    if (json['format'] != LibrarySnapshot.format) {
      issues.add(
        ValidationIssue(
          'format',
          'Expected a "${LibrarySnapshot.format}" backup.',
        ),
      );
    }
    final version = json['schemaVersion'];
    final readableVersion =
        version is int &&
        version >= LibrarySnapshot.oldestReadableSchemaVersion &&
        version <= LibrarySnapshot.schemaVersion;
    if (!readableVersion) {
      issues.add(
        ValidationIssue(
          'schemaVersion',
          'Unsupported schema version: $version '
              '(this build reads schema '
              '${LibrarySnapshot.oldestReadableSchemaVersion} to '
              '${LibrarySnapshot.schemaVersion}).',
        ),
      );
    }
    final exportedAt = json['exportedAt'];
    if (!isCanonicalTimestamp(exportedAt)) {
      issues.add(
        const ValidationIssue(
          'exportedAt',
          'exportedAt must be a canonical UTC ISO-8601 timestamp.',
        ),
      );
    }

    final rawItems = json['items'];
    final rawAssets = json['assets'];
    if (rawItems is! List || rawAssets is! List) {
      if (rawItems is! List) {
        issues.add(const ValidationIssue('items', 'items must be a list.'));
      }
      if (rawAssets is! List) {
        issues.add(const ValidationIssue('assets', 'assets must be a list.'));
      }
      throw ValidationException(issues);
    }

    if (rawItems.length > limits.maxItems) {
      issues.add(
        ValidationIssue(
          'items',
          'A backup can hold at most ${limits.maxItems} copies.',
        ),
      );
    }
    if (rawAssets.length > limits.maxAssets) {
      issues.add(
        ValidationIssue(
          'assets',
          'A backup can hold at most ${limits.maxAssets} images.',
        ),
      );
    }
    if (issues.isNotEmpty) throw ValidationException(issues);

    final items = <MediaItem>[];
    final itemIds = <String>{};
    for (final entry in rawItems) {
      if (entry is! Map) {
        issues.add(
          const ValidationIssue('items', 'Every copy must be an object.'),
        );
        continue;
      }
      final itemJson = entry.cast<String, Object?>();
      // Schema 2 states the flag explicitly; schema 1 predates it and imports
      // with `false`. A present-but-wrong value is rejected in both versions,
      // which MediaItem.fromJson enforces.
      if (version == LibrarySnapshot.schemaVersion &&
          !itemJson.containsKey('isFinished')) {
        issues.add(
          const ValidationIssue(
            'items',
            'Every copy in a schema 2 backup needs an isFinished boolean.',
          ),
        );
        continue;
      }
      final MediaItem item;
      try {
        item = MediaItem.fromJson(itemJson);
      } on FormatException catch (error) {
        issues.add(ValidationIssue('items', error.message));
        continue;
      } on TypeError {
        issues.add(
          const ValidationIssue('items', 'A copy has unexpected types.'),
        );
        continue;
      }
      if (!itemIds.add(item.id)) {
        issues.add(
          ValidationIssue('items', 'Duplicate item id in backup: ${item.id}'),
        );
        continue;
      }
      final itemIssues = ItemValidator.validate(item);
      if (itemIssues.isNotEmpty) {
        issues.addAll(
          itemIssues.map(
            (issue) => ValidationIssue('items.${item.id}', issue.message),
          ),
        );
      }
      items.add(item);
    }

    // Cheap, bounded stage: structure, ids, canonical base64 and decoded sizes
    // before a single byte of image payload is allocated.
    final pending = <_PendingAsset>[];
    final assetIds = <String>{};
    var combined = 0;
    for (final entry in rawAssets) {
      if (entry is! Map) {
        issues.add(
          const ValidationIssue('assets', 'Every image must be an object.'),
        );
        continue;
      }
      final asset = entry.cast<String, Object?>();
      final id = asset['id'];
      final mimeType = asset['mimeType'];
      final data = asset['dataBase64'];
      if (id is! String || mimeType is! String || data is! String) {
        issues.add(
          const ValidationIssue(
            'assets',
            'Images need string id, mimeType and dataBase64 fields.',
          ),
        );
        continue;
      }
      if (!assetIds.add(id)) {
        issues.add(
          ValidationIssue('assets', 'Duplicate asset id in backup: $id'),
        );
        continue;
      }
      if (!AssetMime.isSupported(mimeType)) {
        issues.add(
          ValidationIssue('assets.$id', 'Image must be JPEG, PNG or WebP.'),
        );
        continue;
      }
      final decodedLength = base64DecodedLength(data);
      if (decodedLength == null) {
        issues.add(
          ValidationIssue('assets.$id', 'Image data is not canonical base64.'),
        );
        continue;
      }
      if (decodedLength > limits.maxAssetBytes) {
        issues.add(
          ValidationIssue(
            'assets.$id',
            'Image exceeds the '
                '${_describeBytes(limits.maxAssetBytes)} limit.',
          ),
        );
        continue;
      }
      combined += decodedLength;
      if (combined > limits.maxCombinedAssetBytes) {
        issues.add(
          ValidationIssue(
            'assets',
            'Combined images exceed '
                '${_describeBytes(limits.maxCombinedAssetBytes)}.',
          ),
        );
        break;
      }
      pending.add(
        _PendingAsset(
          id: id,
          mimeType: mimeType,
          data: data,
          byteLength: decodedLength,
        ),
      );
    }

    final assets = <MediaAsset>[];
    if (issues.isEmpty) {
      final referenced = <String>{};
      for (final item in items) {
        final coverId = item.coverAssetId;
        if (coverId != null) referenced.add(coverId);
        referenced.addAll(item.photoAssetIds);
      }
      for (final id in referenced) {
        if (!assetIds.contains(id)) {
          issues.add(
            ValidationIssue('assets', 'Referenced image $id is missing.'),
          );
        }
      }
    }
    if (issues.isEmpty) {
      for (final entry in pending) {
        final Uint8List bytes;
        try {
          bytes = base64Decode(entry.data);
        } on FormatException {
          issues.add(
            ValidationIssue(
              'assets.${entry.id}',
              'Image data is not valid base64.',
            ),
          );
          continue;
        }
        if (bytes.length != entry.byteLength) {
          issues.add(
            ValidationIssue(
              'assets.${entry.id}',
              'Image length is inconsistent.',
            ),
          );
          continue;
        }
        // The closed factory derives the digest, MIME type and dimensions from
        // the bytes; the claimed values must match those derived facts.
        final MediaAsset derived;
        try {
          derived = MediaAsset.fromBytes(bytes, field: 'assets.${entry.id}');
        } on ValidationException catch (error) {
          issues.addAll(error.issues);
          continue;
        }
        if (derived.id != entry.id) {
          issues.add(
            ValidationIssue(
              'assets.${entry.id}',
              'Image id does not match its SHA-256.',
            ),
          );
          continue;
        }
        if (derived.mimeType != entry.mimeType) {
          issues.add(
            ValidationIssue(
              'assets.${entry.id}',
              'Declared ${entry.mimeType} but the bytes are '
                  '${derived.mimeType}.',
            ),
          );
          continue;
        }
        assets.add(derived);
      }
    }

    if (issues.isNotEmpty) throw ValidationException(issues);

    return LibrarySnapshot(
      exportedAt: exportedAt! as String,
      items: items,
      assets: assets,
    );
  }

  /// Human-readable byte caps: `5 MiB` for real limits, `40 bytes` in tests.
  static String _describeBytes(int bytes) =>
      bytes < 1024 * 1024 ? '$bytes bytes' : '${bytes ~/ (1024 * 1024)} MiB';
}

class _PendingAsset {
  const _PendingAsset({
    required this.id,
    required this.mimeType,
    required this.data,
    required this.byteLength,
  });

  final String id;
  final String mimeType;
  final String data;
  final int byteLength;
}

/// Caps for one backup payload.
///
/// The app always uses [SnapshotCodec.defaultLimits]; tests pass tiny values so
/// the cap logic can be exercised without building multi-megabyte fixtures.
class SnapshotLimits {
  const SnapshotLimits({
    this.maxFileBytes = SnapshotCodec.maxFileBytes,
    this.maxItems = SnapshotCodec.maxItems,
    this.maxAssets = SnapshotCodec.maxAssets,
    this.maxAssetBytes = SnapshotCodec.maxAssetBytes,
    this.maxCombinedAssetBytes = SnapshotCodec.maxCombinedAssetBytes,
  });

  final int maxFileBytes;
  final int maxItems;
  final int maxAssets;
  final int maxAssetBytes;
  final int maxCombinedAssetBytes;
}
