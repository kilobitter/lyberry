import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/image_ingest.dart';

import '../support/fake_snapshot_io.dart';
import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

Map<String, Object?> itemMap({
  String id = '00000000-0000-4000-8000-000000000001',
  String? coverAssetId,
  List<String> photoAssetIds = const <String>[],
  Object? source,
  Object? isFinished = false,
  bool includeFinished = true,
  String createdAt = '2026-09-23T10:00:00.000Z',
  String updatedAt = '2026-09-23T10:00:00.000Z',
}) => <String, Object?>{
  'id': id,
  'medium': 'book',
  'title': 'Dune',
  'creator': '',
  'publisher': '',
  'description': '',
  'platform': '',
  'year': 1965,
  'barcode': null,
  'rating': null,
  'review': '',
  'notes': '',
  if (includeFinished) 'isFinished': isFinished,
  'coverAssetId': coverAssetId,
  'photoAssetIds': photoAssetIds,
  'source': source,
  'createdAt': createdAt,
  'updatedAt': updatedAt,
};

Map<String, Object?> assetMap({
  String id =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String mimeType = 'image/png',
  String? data,
}) => <String, Object?>{
  'id': id,
  'mimeType': mimeType,
  'dataBase64': data ?? base64Encode(pngBytes(width: 4, height: 4)),
};

Map<String, Object?> payload({
  List<Object?>? items,
  List<Object?>? assets,
  Object? schemaVersion,
  Object? exportedAt,
}) => <String, Object?>{
  'format': 'lyberry',
  'schemaVersion': schemaVersion ?? LibrarySnapshot.schemaVersion,
  'exportedAt': exportedAt ?? '2026-09-23T10:00:00.000Z',
  'items': items ?? <Object?>[itemMap()],
  'assets': assets ?? <Object?>[],
};

void main() {
  group('snapshot caps', () {
    test('rejects a file over the byte cap before parsing', () {
      expect(
        () => SnapshotCodec.decode(
          '{"format":"lyberry"}',
          limits: const SnapshotLimits(maxFileBytes: 8),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('bytes or smaller'),
          ),
        ),
      );
    });

    test('rejects a loose or unreadable schema version', () {
      for (final version in <Object?>[1.0, '1', 3, 99]) {
        expect(
          () => SnapshotCodec.decodeMap(payload(schemaVersion: version)),
          throwsA(
            isA<ValidationException>().having(
              (error) => error.message,
              'message',
              contains('Unsupported schema version'),
            ),
          ),
          reason: '$version',
        );
      }
      final missingVersion = payload()..remove('schemaVersion');
      expect(
        () => SnapshotCodec.decodeMap(missingVersion),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Unsupported schema version'),
          ),
        ),
        reason: 'a missing schemaVersion must not default to 1',
      );
    });

    test('rejects non-canonical exportedAt and item timestamps', () {
      for (final value in <String>[
        '2026-09-23T10:00:00Z',
        '2026-09-23T10:00:00+02:00',
        'yesterday',
      ]) {
        expect(
          () => SnapshotCodec.decodeMap(payload(exportedAt: value)),
          throwsA(isA<ValidationException>()),
          reason: value,
        );
      }
      expect(
        () => SnapshotCodec.decodeMap(
          payload(items: <Object?>[itemMap(createdAt: '2026-09-23T10:00:00Z')]),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('canonical'),
          ),
        ),
      );
    });

    test('rejects malformed source blocks instead of dropping them', () {
      final brokenSources = <Object?>[
        'not a map',
        <String, Object?>{'providerId': 5, 'externalId': 'x'},
        <String, Object?>{'providerId': '', 'externalId': 'x'},
        <String, Object?>{'providerId': 'p'},
        <String, Object?>{'providerId': 'p', 'externalId': 'x', 'url': 7},
      ];
      for (final source in brokenSources) {
        expect(
          () => SnapshotCodec.decodeMap(
            payload(items: <Object?>[itemMap(source: source)]),
          ),
          throwsA(isA<ValidationException>()),
          reason: '$source',
        );
      }
    });

    test('rejects per-image and combined image byte caps', () {
      final twentyBytes = base64Encode(List<int>.filled(20, 7));
      final firstId =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final secondId =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final thirdId =
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

      expect(
        () => SnapshotCodec.decodeMap(
          payload(
            assets: <Object?>[assetMap(id: firstId, data: twentyBytes)],
          ),
          limits: const SnapshotLimits(maxAssetBytes: 16),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('16 bytes'),
          ),
        ),
      );

      expect(
        () => SnapshotCodec.decodeMap(
          payload(
            assets: <Object?>[
              assetMap(id: secondId, data: twentyBytes),
              assetMap(id: thirdId, data: twentyBytes),
            ],
          ),
          limits: const SnapshotLimits(
            maxAssetBytes: 24,
            maxCombinedAssetBytes: 30,
          ),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Combined images exceed 30 bytes'),
          ),
        ),
      );
    });

    test('rejects item and asset count caps', () {
      expect(
        () => SnapshotCodec.decodeMap(
          payload(
            items: <Object?>[
              itemMap(),
              itemMap(id: '00000000-0000-4000-8000-000000000002'),
            ],
          ),
          limits: const SnapshotLimits(maxItems: 1),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('at most 1 copies'),
          ),
        ),
      );
    });
  });

  group('strict payload checks', () {
    test('rejects duplicate item and asset identities', () {
      expect(
        () => SnapshotCodec.decodeMap(
          payload(items: <Object?>[itemMap(), itemMap()]),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Duplicate item id'),
          ),
        ),
      );
      expect(
        () => SnapshotCodec.decodeMap(
          payload(assets: <Object?>[assetMap(), assetMap()]),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Duplicate asset id'),
          ),
        ),
      );
    });

    test('rejects base64 that is not canonical', () {
      for (final data in <String>['abc', 'ab=c', 'a b c d', '====']) {
        expect(
          () => SnapshotCodec.decodeMap(
            payload(assets: <Object?>[assetMap(data: data)]),
          ),
          throwsA(
            isA<ValidationException>().having(
              (error) => error.message,
              'message',
              contains('canonical base64'),
            ),
          ),
          reason: data,
        );
      }
    });

    test('rejects a referenced image that is not in the file', () {
      final missingId =
          '9999999999999999999999999999999999999999999999999999999999999999';
      expect(
        () => SnapshotCodec.decodeMap(
          payload(items: <Object?>[itemMap(coverAssetId: missingId)]),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('is missing'),
          ),
        ),
      );
    });

    test('rejects an image whose bytes disagree with its metadata', () {
      final asset = const ImageIngest().buildAsset(
        pngBytes(width: 6, height: 6),
      );
      expect(
        () => SnapshotCodec.decodeMap(
          payload(
            assets: <Object?>[
              assetMap(
                id: asset.id,
                mimeType: 'image/jpeg',
                data: base64Encode(asset.bytes),
              ),
            ],
          ),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Declared image/jpeg'),
          ),
        ),
      );
    });

    test('rejects valid base64 that is not a supported image', () {
      expect(
        () => SnapshotCodec.decodeMap(
          payload(
            assets: <Object?>[
              assetMap(data: base64Encode(utf8.encode('not an image'))),
            ],
          ),
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('no partial mutation', () {
    test('a malformed file leaves the library untouched', () async {
      final repository = InMemoryMediaRepository();
      final service = BackupService(
        repository: repository,
        io: FakeSnapshotIo(
          pickResult: const PickedBackup(
            fileName: 'broken.lyberry.json',
            contents: '{"format":"lyberry","schemaVersion":1}',
            byteLength: 36,
          ),
        ),
        clock: FixedClock(kBaseTime),
        useIsolate: false,
      );

      await expectLater(
        service.chooseImport(),
        throwsA(isA<ValidationException>()),
      );
      expect(await repository.countItems(), 0);
    });

    test('a cancelled picker changes nothing', () async {
      final repository = InMemoryMediaRepository();
      final service = BackupService(
        repository: repository,
        io: FakeSnapshotIo(),
        clock: FixedClock(kBaseTime),
        useIsolate: false,
      );

      expect(await service.chooseImport(), isNull);
      expect(await repository.countItems(), 0);
    });
  });

  group('export bounds', () {
    test('refuses an export that would exceed the byte cap', () {
      final snapshot = LibrarySnapshot(
        exportedAt: '2026-09-23T10:00:00.000Z',
        items: <MediaItem>[
          sampleItem(
            id: '00000000-0000-4000-8000-000000000001',
            title: '日本語のタイトル' * 20,
            notes: 'é' * 120,
          ),
        ],
        assets: const <MediaAsset>[],
      );

      expect(
        () => SnapshotCodec.encode(
          snapshot,
          limits: const SnapshotLimits(maxFileBytes: 512),
        ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('would be larger than 512 bytes'),
          ),
        ),
      );
    });

    test('counts UTF-8 bytes rather than string code units', () async {
      final repository = InMemoryMediaRepository();
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000002',
          title: 'Zażółć gęślą jaźń — 日本語',
        ),
      );
      final io = FakeSnapshotIo();
      final result = await BackupService(
        repository: repository,
        io: io,
        clock: FixedClock(kBaseTime),
        useIsolate: false,
      ).export();

      expect(result.cancelled, isFalse);
      expect(
        result.byteLength,
        SnapshotCodec.exactUtf8Length(io.savedContents!),
      );
      expect(
        result.byteLength,
        greaterThan(io.savedContents!.length),
        reason: 'multibyte metadata must be counted in bytes',
      );
    });

    test('an over-limit export fails before the file picker opens', () async {
      final repository = InMemoryMediaRepository();
      await repository.createItem(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000003',
          title: 'x' * 400,
        ),
      );
      final io = FakeSnapshotIo();
      final service = BackupService(
        repository: repository,
        io: io,
        clock: FixedClock(kBaseTime),
        useIsolate: false,
        limits: const SnapshotLimits(maxFileBytes: 256),
      );

      await expectLater(service.export(), throwsA(isA<ValidationException>()));
      expect(
        io.savedFileName,
        isNull,
        reason: 'the picker must never open for an over-limit backup',
      );
    });

    test('verified assets are trusted and hand-built ones are not', () {
      final real = const ImageIngest().buildAsset(
        pngBytes(width: 5, height: 5),
      );
      expect(real.contentVerified, isTrue);

      final handBuilt = MediaAsset(
        id: real.id,
        mimeType: real.mimeType,
        bytes: real.bytes,
        width: real.width,
        height: real.height,
      );
      expect(
        handBuilt.contentVerified,
        isFalse,
        reason:
            'a hand-built asset must still be verified at the write boundary',
      );

      final decoded = SnapshotCodec.decode(
        SnapshotCodec.encode(
          LibrarySnapshot(
            exportedAt: '2026-09-23T10:00:00.000Z',
            items: <MediaItem>[
              sampleItem(
                id: '00000000-0000-4000-8000-000000000004',
                photoAssetIds: <String>[real.id],
              ),
            ],
            assets: <MediaAsset>[real],
          ),
        ),
      );
      expect(decoded.assets.single.contentVerified, isTrue);
    });

    test('does not reject a valid payload on a rough size estimate', () {
      final notes = 'A' * 4000;
      final snapshot = LibrarySnapshot(
        exportedAt: '2026-09-23T10:00:00.000Z',
        items: <MediaItem>[
          sampleItem(id: '00000000-0000-4000-8000-000000000005', notes: notes),
        ],
        assets: const <MediaAsset>[],
      );
      const generous = SnapshotLimits(maxFileBytes: 1 << 30);
      final actual = SnapshotCodec.exactUtf8Length(
        SnapshotCodec.encode(snapshot, limits: generous),
      );
      expect(
        actual,
        lessThan(6000),
        reason: 'ASCII metadata does not cost four bytes per character',
      );

      const limit = SnapshotLimits(maxFileBytes: 6000);
      final payload = SnapshotCodec.encode(snapshot, limits: limit);
      expect(
        SnapshotCodec.decode(payload, limits: limit).items.single.notes,
        notes,
      );
    });

    test('counts escaped control characters and nested source fields', () {
      final escaped = '\u0001' * 600; // six bytes each once escaped
      final escapedSnapshot = LibrarySnapshot(
        exportedAt: '2026-09-23T10:00:00.000Z',
        items: <MediaItem>[
          sampleItem(
            id: '00000000-0000-4000-8000-000000000006',
            notes: escaped,
          ),
        ],
        assets: const <MediaAsset>[],
      );
      const generous = SnapshotLimits(maxFileBytes: 1 << 30);
      final escapedLength = SnapshotCodec.exactUtf8Length(
        SnapshotCodec.encode(escapedSnapshot, limits: generous),
      );
      expect(escapedLength, greaterThan(3600));
      expect(
        () => SnapshotCodec.encode(
          escapedSnapshot,
          limits: SnapshotLimits(maxFileBytes: escapedLength - 1),
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        SnapshotCodec.encode(
          escapedSnapshot,
          limits: SnapshotLimits(maxFileBytes: escapedLength),
        ),
        isNotEmpty,
      );

      final nested = LibrarySnapshot(
        exportedAt: '2026-09-23T10:00:00.000Z',
        items: <MediaItem>[
          sampleItem(
            id: '00000000-0000-4000-8000-000000000007',
            source: MediaSource(
              providerId: 'p' * 200,
              externalId: 'e' * 200,
              url: 'https://example.org/${'x' * 500}',
            ),
          ),
        ],
        assets: const <MediaAsset>[],
      );
      final nestedLength = SnapshotCodec.exactUtf8Length(
        SnapshotCodec.encode(nested, limits: generous),
      );
      expect(
        nestedLength,
        greaterThan(
          SnapshotCodec.exactUtf8Length(
            SnapshotCodec.encode(
              LibrarySnapshot(
                exportedAt: '2026-09-23T10:00:00.000Z',
                items: <MediaItem>[
                  sampleItem(id: '00000000-0000-4000-8000-000000000008'),
                ],
                assets: const <MediaAsset>[],
              ),
              limits: generous,
            ),
          ),
        ),
        reason: 'nested source fields are part of the payload',
      );
      expect(
        () => SnapshotCodec.encode(
          nested,
          limits: SnapshotLimits(maxFileBytes: nestedLength - 1),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('round-trips multibyte metadata that fits the cap', () {
      final notes = '日本語のメモ' * 100;
      final snapshot = LibrarySnapshot(
        exportedAt: '2026-09-23T10:00:00.000Z',
        items: <MediaItem>[
          sampleItem(
            id: '00000000-0000-4000-8000-000000000009',
            title: 'Zażółć gęślą jaźń',
            notes: notes,
          ),
        ],
        assets: const <MediaAsset>[],
      );
      const limit = SnapshotLimits(maxFileBytes: 8000);
      final payload = SnapshotCodec.encode(snapshot, limits: limit);
      final decoded = SnapshotCodec.decode(payload, limits: limit);

      expect(decoded.items.single.notes, notes);
      expect(decoded.items.single.title, 'Zażółć gęślą jaźń');
    });
  });
}
