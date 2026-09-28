import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_support.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('round-trips a >2 MiB image through chunked reads and export', () async {
    final directory = createTempDir('chunked_asset');
    final repository = await openTestRepository('${directory.path}/lyberry.db');
    addTearDown(() async {
      await repository.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    final bytes = largePngBytes();
    expect(
      bytes.length,
      greaterThan(2 * 1024 * 1024),
      reason: 'the fixture must exceed one CursorWindow-sized slice',
    );
    final asset = const ImageIngest().buildAsset(bytes);
    expect(asset.byteSize, bytes.length);

    final item = sampleItem(
      id: '00000000-0000-4000-8000-0000000000f1',
      title: 'Large photo',
      photoAssetIds: <String>[asset.id],
    );
    await repository.createItem(item, assets: <MediaAsset>[asset]);

    // Reading it back goes through the bounded substr slices rather than one
    // oversized cursor row.
    final read = await repository.getAsset(asset.id);
    expect(read, isNotNull);
    expect(read!.byteSize, bytes.length);
    expect(sha256.convert(read.bytes).toString(), asset.id);
    expect(read.bytes.sublist(0, 8), bytes.sublist(0, 8));

    final exported = await repository.exportSnapshot();
    final exportedAsset = exported.assets.single;
    expect(exportedAsset.byteSize, bytes.length);
    expect(sha256.convert(exportedAsset.bytes).toString(), asset.id);
  });
}
