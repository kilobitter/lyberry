import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/image_ingest.dart';

import '../support/test_support.dart';

void main() {
  final cover = const ImageIngest().buildAsset(pngBytes());

  LibrarySnapshot snapshotWith({
    List<MediaItem>? items,
    List<MediaAsset>? assets,
  }) {
    return LibrarySnapshot(
      exportedAt: kBaseTimestamp,
      items:
          items ??
          <MediaItem>[
            sampleItem(
              id: '00000000-0000-4000-8000-000000000001',
              rating: 4.5,
              coverAssetId: cover.id,
            ),
          ],
      assets: assets ?? <MediaAsset>[cover],
    );
  }

  test('round-trips a snapshot through JSON', () {
    final decoded = SnapshotCodec.decode(SnapshotCodec.encode(snapshotWith()));
    expect(decoded.items.single.rating, 4.5);
    expect(decoded.assets.single.id, cover.id);
    expect(decoded.assets.single.width, cover.width);
    expect(decoded.exportedAt, kBaseTimestamp);
  });

  test('rejects a payload that is not JSON or not a lyberry file', () {
    expect(
      () => SnapshotCodec.decode('{not json'),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => SnapshotCodec.decode(
        jsonEncode(<String, Object?>{'format': 'other'}),
      ),
      throwsA(isA<ValidationException>()),
    );
  });

  test('rejects an unknown schema version', () {
    final payload = snapshotWith().toJson()..['schemaVersion'] = 99;
    expect(
      () => SnapshotCodec.decodeMap(payload),
      throwsA(isA<ValidationException>()),
    );
  });

  test('rejects duplicate item and asset identities', () {
    final item = sampleItem(id: '00000000-0000-4000-8000-000000000001');
    expect(
      () => SnapshotCodec.decodeMap(
        snapshotWith(items: <MediaItem>[item, item]).toJson(),
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
        snapshotWith(assets: <MediaAsset>[cover, cover]).toJson(),
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

  test('rejects an asset whose id does not match its bytes', () {
    final payload = snapshotWith().toJson();
    final assets = payload['assets']! as List<Object?>;
    // Forge the id consistently everywhere, so the reference check passes and
    // the SHA-256 check is the one that has to catch it.
    (assets.first! as Map<String, Object?>)['id'] = 'f' * 64;
    final items = payload['items']! as List<Object?>;
    (items.first! as Map<String, Object?>)['coverAssetId'] = 'f' * 64;

    expect(
      () => SnapshotCodec.decodeMap(payload),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('SHA-256'),
        ),
      ),
    );
  });

  test('rejects base64 that is not an image and missing references', () {
    final payload = snapshotWith().toJson();
    final assets = payload['assets']! as List<Object?>;
    (assets.first! as Map<String, Object?>)['dataBase64'] = base64Encode(
      utf8.encode('not an image'),
    );
    expect(
      () => SnapshotCodec.decodeMap(payload),
      throwsA(isA<ValidationException>()),
    );

    final missing = snapshotWith(assets: <MediaAsset>[]).toJson();
    expect(
      () => SnapshotCodec.decodeMap(missing),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('is missing'),
        ),
      ),
    );
  });

  test('rejects an item that breaks the domain contract', () {
    final payload = snapshotWith(
      items: <MediaItem>[
        sampleItem(id: '00000000-0000-4000-8000-000000000001', rating: 4.25),
      ],
      assets: <MediaAsset>[],
    ).toJson();
    expect(
      () => SnapshotCodec.decodeMap(payload),
      throwsA(
        isA<ValidationException>().having(
          (error) => error.message,
          'message',
          contains('half-star'),
        ),
      ),
    );
  });
}
