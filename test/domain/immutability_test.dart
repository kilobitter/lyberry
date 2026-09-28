import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/services/image_ingest.dart';

import '../support/test_support.dart';

void main() {
  group('MediaAsset immutability', () {
    test('copies the caller bytes and exposes a read-only view', () {
      final callerBytes = Uint8List.fromList(pngBytes(width: 10, height: 10));
      final asset = MediaAsset(
        id: 'a' * 64,
        mimeType: AssetMime.png,
        bytes: callerBytes,
        width: 10,
        height: 10,
      );

      // Mutating the caller's buffer cannot change the stored asset.
      callerBytes[0] = 0x00;
      expect(asset.bytes[0], 0x89);

      // And the exposed view refuses mutation.
      expect(() => asset.bytes[0] = 0x00, throwsUnsupportedError);
      expect(asset.bytes[0], 0x89);
    });
  });

  group('MediaItem immutability', () {
    test('copies the photo id list and exposes it read-only', () {
      final callerList = <String>['b' * 64];
      final item = sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        photoAssetIds: callerList,
      );

      callerList.add('c' * 64);
      expect(item.photoAssetIds, <String>['b' * 64]);
      expect(() => item.photoAssetIds.add('d' * 64), throwsUnsupportedError);

      final derived = item.copyWith(photoAssetIds: <String>['e' * 64]);
      expect(derived.photoAssetIds, <String>['e' * 64]);
      expect(() => derived.photoAssetIds.clear(), throwsUnsupportedError);
    });
  });

  group('LibrarySnapshot immutability', () {
    test('copies item and asset lists and exposes them read-only', () {
      final asset = const ImageIngest().buildAsset(pngBytes());
      final items = <MediaItem>[
        sampleItem(id: '00000000-0000-4000-8000-000000000002'),
      ];
      final assets = <MediaAsset>[asset];

      final snapshot = LibrarySnapshot(
        exportedAt: kBaseTimestamp,
        items: items,
        assets: assets,
      );

      items.clear();
      assets.clear();
      expect(snapshot.items, hasLength(1));
      expect(snapshot.assets, hasLength(1));
      expect(
        () => snapshot.items.add(
          sampleItem(id: '00000000-0000-4000-8000-000000000003'),
        ),
        throwsUnsupportedError,
      );
      expect(() => snapshot.assets.clear(), throwsUnsupportedError);
    });
  });
}
