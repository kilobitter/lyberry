import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/image_ingest.dart';

import '../support/test_support.dart';
import '../support/photo_fixtures.dart';

void main() {
  group('image ingest', () {
    test('builds a content-addressed PNG asset', () {
      final bytes = pngBytes(width: 20, height: 10);
      final asset = const ImageIngest().buildAsset(bytes);

      expect(asset.mimeType, AssetMime.png);
      expect(asset.id, sha256.convert(bytes).toString());
      expect(asset.id.length, 64);
      expect(asset.width, 20);
      expect(asset.height, 10);
      expect(asset.byteSize, bytes.length);
      expect(ItemValidator.validateAsset(asset), isEmpty);
    });

    test('accepts JPEG bytes', () {
      final asset = const ImageIngest().buildAsset(jpegBytes());
      expect(asset.mimeType, AssetMime.jpeg);
    });

    test('accepts an EXIF-rotated JPEG and keeps its raw dimensions', () {
      final bytes = quadJpeg(orientation: 6);
      final asset = const ImageIngest().buildAsset(bytes);

      expect(asset.mimeType, AssetMime.jpeg);
      expect(asset.width, 240, reason: 'the stored size stays the header size');
      expect(asset.height, 120);
      expect(asset.contentVerified, isTrue);
      expect(ItemValidator.validateAsset(asset), isEmpty);
      expect(ImageInspector.verifyAsset(asset), isEmpty);
    });

    test('rejects payloads over the byte limit before decoding', () {
      final ingest = ImageIngest(limits: const ImageLimits(maxBytes: 64));
      expect(
        () => ingest.buildAsset(pngBytes(width: 40, height: 40)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects images over the pixel limit', () {
      final ingest = ImageIngest(limits: const ImageLimits(maxPixels: 100));
      expect(
        () => ingest.buildAsset(pngBytes(width: 20, height: 20)),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('megapixel'),
          ),
        ),
      );
    });

    test('rejects non-image and unsupported containers', () {
      final text = Uint8List.fromList('this is not an image'.codeUnits);
      expect(
        () => const ImageIngest().buildAsset(text),
        throwsA(isA<ValidationException>()),
      );

      final gif = Uint8List.fromList(<int>[
        0x47,
        0x49,
        0x46,
        0x38,
        0x39,
        0x61,
        0x01,
        0x00,
        0x01,
        0x00,
      ]);
      expect(
        () => const ImageIngest().buildAsset(gif),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('JPEG, PNG or WebP'),
          ),
        ),
      );
    });

    test('rejects an empty payload', () {
      expect(
        () => const ImageIngest().buildAsset(Uint8List(0)),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
