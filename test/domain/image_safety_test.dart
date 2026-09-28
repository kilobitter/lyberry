import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/image_ingest.dart';

import '../support/test_support.dart';
import '../support/photo_fixtures.dart';

/// Reveals oversized dimensions in the file header while keeping the payload
/// tiny: the inspector must reject on the header, never on a decoded raster.
Uint8List pngDeclaringSize(int width, int height) {
  final bytes = Uint8List.fromList(pngBytes(width: 8, height: 8));
  void writeU32(int offset, int value) {
    bytes[offset] = (value >> 24) & 0xFF;
    bytes[offset + 1] = (value >> 16) & 0xFF;
    bytes[offset + 2] = (value >> 8) & 0xFF;
    bytes[offset + 3] = value & 0xFF;
  }

  writeU32(16, width);
  writeU32(20, height);
  return bytes;
}

/// Same idea for JPEG: patch the SOF frame header.
Uint8List jpegDeclaringSize(int width, int height) {
  final bytes = Uint8List.fromList(jpegBytes(width: 8, height: 8));
  for (var index = 2; index + 9 < bytes.length; index++) {
    if (bytes[index] == 0xFF &&
        (bytes[index + 1] == 0xC0 || bytes[index + 1] == 0xC2)) {
      bytes[index + 5] = (height >> 8) & 0xFF;
      bytes[index + 6] = height & 0xFF;
      bytes[index + 7] = (width >> 8) & 0xFF;
      bytes[index + 8] = width & 0xFF;
      return bytes;
    }
  }
  throw StateError('no start-of-frame marker found');
}

/// A PNG carrying an acTL chunk, which marks it as animated.
Uint8List animatedPngBytes() {
  final base = pngBytes(width: 8, height: 8);
  final chunk = <int>[
    0, 0, 0, 8, // length
    0x61, 0x63, 0x54, 0x4C, // 'acTL'
    0, 0, 0, 2, // numFrames
    0, 0, 0, 0, // numPlays
    0, 0, 0, 0, // crc (not verified by the header reader)
  ];
  return Uint8List.fromList(<int>[
    ...base.sublist(0, 33),
    ...chunk,
    ...base.sublist(33),
  ]);
}

/// Minimal VP8X header with the animation flag set.
Uint8List animatedWebpBytes() {
  final bytes = Uint8List(30);
  bytes.setAll(0, 'RIFF'.codeUnits);
  bytes.setAll(8, 'WEBP'.codeUnits);
  bytes.setAll(12, 'VP8X'.codeUnits);
  bytes[16] = 10; // chunk size, little endian
  bytes[20] = 0x02; // animation flag
  bytes[24] = 2; // canvas width - 1
  bytes[27] = 1; // canvas height - 1
  return bytes;
}

List<int> _pngChunk(String type, List<int> data) {
  final length = <int>[
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
  ];
  return <int>[...length, ...type.codeUnits, ...data, 0, 0, 0, 0];
}

/// A PNG whose animation control chunk sits behind [ancillary] text chunks.
Uint8List pngWithAncillaryChunksThenAnimation(int ancillary) {
  final base = pngBytes(width: 8, height: 8);
  final ihdr = base.sublist(8, 33); // length + type + 13 data bytes
  final idatOnwards = base.sublist(33);
  final text = _pngChunk('tEXt', <int>[0x61, 0x00, 0x62]);
  final animation = _pngChunk('acTL', <int>[0, 0, 0, 2, 0, 0, 0, 0]);
  return Uint8List.fromList(<int>[
    ...base.sublist(0, 8),
    ...ihdr,
    for (var index = 0; index < ancillary; index++) ...text,
    ...animation,
    ...idatOnwards,
  ]);
}

/// A PNG with a second, conflicting IHDR before the pixel data.
Uint8List pngWithConflictingHeader(int width, int height) {
  final base = pngBytes(width: 8, height: 8);
  final ihdr = base.sublist(8, 33);
  final conflicting = List<int>.of(ihdr);
  void writeU32(int offset, int value) {
    conflicting[offset] = (value >> 24) & 0xFF;
    conflicting[offset + 1] = (value >> 16) & 0xFF;
    conflicting[offset + 2] = (value >> 8) & 0xFF;
    conflicting[offset + 3] = value & 0xFF;
  }

  writeU32(8, width);
  writeU32(12, height);
  return Uint8List.fromList(<int>[
    ...base.sublist(0, 33),
    ...conflicting,
    ...base.sublist(33),
  ]);
}

/// Wraps a real VP8 bitstream in a VP8X container with the given canvas.
Uint8List webpWithCanvas(int canvasWidth, int canvasHeight) {
  final fixture = File('test/fixtures/sample.webp').readAsBytesSync();
  final vp8 = fixture.sublist(12); // 'VP8 ' chunk header and payload
  final vp8x = <int>[
    ...'VP8X'.codeUnits,
    10, 0, 0, 0, // chunk size
    0x00, // no animation
    0, 0, 0, // reserved
    (canvasWidth - 1) & 0xFF,
    ((canvasWidth - 1) >> 8) & 0xFF,
    ((canvasWidth - 1) >> 16) & 0xFF,
    (canvasHeight - 1) & 0xFF,
    ((canvasHeight - 1) >> 8) & 0xFF,
    ((canvasHeight - 1) >> 16) & 0xFF,
  ];
  final body = <int>[...vp8x, ...vp8];
  final riffSize = body.length + 4;
  return Uint8List.fromList(<int>[
    ...'RIFF'.codeUnits,
    riffSize & 0xFF,
    (riffSize >> 8) & 0xFF,
    (riffSize >> 16) & 0xFF,
    (riffSize >> 24) & 0xFF,
    ...'WEBP'.codeUnits,
    ...body,
  ]);
}

void main() {
  group('header-first image safety', () {
    test('rejects a PNG pixel bomb from its header, not from a raster', () {
      final bomb = pngDeclaringSize(60000, 60000);

      expect(
        () => const ImageIngest().buildAsset(bomb),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('megapixel'),
          ),
        ),
      );
    });

    test('rejects a truncated PNG whose header claims huge dimensions', () {
      final headerOnly = pngDeclaringSize(50000, 50000).sublist(0, 33);

      expect(
        () => ImageInspector.inspect(Uint8List.fromList(headerOnly)),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('megapixel'),
          ),
        ),
      );
    });

    test('rejects a JPEG pixel bomb from its frame header', () {
      final bomb = jpegDeclaringSize(30000, 30000);

      expect(
        () => const ImageIngest().buildAsset(bomb),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('megapixel'),
          ),
        ),
      );
    });

    test('applies the pixel bound to a valid image before decoding', () {
      final ingest = ImageIngest(limits: const ImageLimits(maxPixels: 1000));

      expect(
        () => ingest.buildAsset(pngBytes(width: 60, height: 60)),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => ingest.buildAsset(pngBytes(width: 30, height: 30)),
        returnsNormally,
      );
    });

    test('rejects animated PNG and animated WebP', () {
      expect(
        () => ImageInspector.inspect(animatedPngBytes()),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Animated'),
          ),
        ),
      );
      expect(
        () => ImageInspector.inspect(animatedWebpBytes()),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Animated'),
          ),
        ),
      );
    });

    test('rejects animation hidden behind many ancillary chunks', () {
      final sneaky = pngWithAncillaryChunksThenAnimation(200);

      expect(
        () => ImageInspector.inspect(sneaky),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('Animated'),
          ),
        ),
      );
    });

    test('refuses a chunk pile instead of assuming it is static', () {
      final pile = pngWithAncillaryChunksThenAnimation(1200);

      expect(
        () => ImageInspector.inspect(pile),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('too many header chunks'),
          ),
        ),
      );
    });

    test('rejects a conflicting duplicate IHDR before any decode', () {
      expect(
        () => ImageInspector.inspect(pngWithConflictingHeader(16, 16)),
        throwsA(isA<ValidationException>()),
      );
      // A duplicate header claiming a huge raster is refused by the decoder's
      // own metadata stage, so no raster is ever allocated for it.
      expect(
        () => ImageInspector.inspect(pngWithConflictingHeader(40000, 40000)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('rejects a WebP canvas that contradicts its bitstream', () {
      // Canvas smaller than the embedded 320x214 frame.
      expect(
        () => ImageInspector.inspect(webpWithCanvas(4, 4)),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('conflicting header information'),
          ),
        ),
      );
      // Canvas claiming a raster far larger than its bitstream.
      expect(
        () => ImageInspector.inspect(webpWithCanvas(60000, 60000)),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('megapixel'),
          ),
        ),
      );
    });
  });

  group('EXIF orientation ingest', () {
    // The installed JPEG decoder bakes the EXIF orientation and clears the tag
    // before returning pixels, so an honest quarter-turn photo legitimately
    // reports the transpose of its own header. The allowance is JPEG-only and
    // anchored to the exact transpose; every other disagreement still fails.
    for (final orientation in <int>[1, 2, 3, 4]) {
      test('orientation $orientation ingests at its declared size', () {
        final bytes = quadJpeg(orientation: orientation);
        expect(exifOrientation(bytes), orientation);

        final inspected = ImageInspector.inspect(bytes);
        expect(inspected.mimeType, AssetMime.jpeg);
        expect(inspected.width, 240);
        expect(inspected.height, 120);

        final asset = const ImageIngest().buildAsset(bytes);
        expect(asset.width, 240);
        expect(asset.height, 120);
        expect(asset.contentVerified, isTrue);
        expect(ImageInspector.verifyAsset(asset), isEmpty);
      });
    }

    for (final orientation in <int>[5, 6, 7, 8]) {
      test('orientation $orientation ingests and keeps the raw dimensions', () {
        final bytes = quadJpeg(orientation: orientation);
        expect(exifOrientation(bytes), orientation);

        final inspected = ImageInspector.inspect(bytes);
        expect(inspected.width, 240, reason: 'the stored size stays raw');
        expect(inspected.height, 120);

        final asset = const ImageIngest().buildAsset(bytes);
        expect(asset.width, 240, reason: 'stored-asset invariants do not move');
        expect(asset.height, 120);
        expect(asset.contentVerified, isTrue);
        expect(ImageInspector.verifyAsset(asset), isEmpty);
      });
    }

    test('a mirrored quarter turn is accepted the same way', () {
      // Orientations 5 and 7 mirror as well as turn; the raster is still the
      // exact transpose of the header.
      final five = ImageInspector.inspect(quadJpeg(orientation: 5));
      final seven = ImageInspector.inspect(quadJpeg(orientation: 7));
      expect(five.width, 240);
      expect(five.height, 120);
      expect(seven.width, 240);
      expect(seven.height, 120);
    });

    test('the transpose allowance stays JPEG-only', () {
      // A container disagreement in another format keeps failing closed.
      expect(
        () => ImageInspector.inspect(webpWithCanvas(4, 4)),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.message,
            'message',
            contains('conflicting header information'),
          ),
        ),
      );
      expect(
        () => ImageInspector.inspect(pngWithConflictingHeader(40000, 40000)),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('webp fixture', () {
    // Provenance: https://www.gstatic.com/webp/gallery/1.sm.webp (official
    // Google WebP gallery sample, VP8 lossy, 320x214).
    final webpBytes = File('test/fixtures/sample.webp').readAsBytesSync();

    test('accepts a real WebP file and reads its header dimensions', () {
      final inspected = ImageInspector.inspect(webpBytes);
      expect(inspected.mimeType, AssetMime.webp);
      expect(inspected.width, 320);
      expect(inspected.height, 214);
    });

    test('builds a valid, verifiable asset from the WebP fixture', () {
      final asset = const ImageIngest().buildAsset(webpBytes);

      expect(asset.mimeType, AssetMime.webp);
      expect(asset.width, 320);
      expect(asset.height, 214);
      expect(ItemValidator.validateAsset(asset), isEmpty);
      expect(ImageInspector.verifyAsset(asset), isEmpty);
    });
  });

  group('asset verification', () {
    test('accepts a genuine asset and rejects metadata that lies', () {
      final real = const ImageIngest().buildAsset(
        pngBytes(width: 12, height: 9),
      );
      expect(ImageInspector.verifyAsset(real), isEmpty);

      final forgedId = MediaAsset(
        id: '0' * 64,
        mimeType: real.mimeType,
        bytes: real.bytes,
        width: real.width,
        height: real.height,
      );
      expect(
        ImageInspector.verifyAsset(forgedId).map((issue) => issue.message),
        contains(contains('SHA-256')),
      );

      final lyingMime = MediaAsset(
        id: real.id,
        mimeType: AssetMime.jpeg,
        bytes: real.bytes,
        width: real.width,
        height: real.height,
      );
      expect(
        ImageInspector.verifyAsset(lyingMime).map((issue) => issue.message),
        contains(contains('Declared image/jpeg')),
      );

      final lyingSize = MediaAsset(
        id: real.id,
        mimeType: real.mimeType,
        bytes: real.bytes,
        width: 999,
        height: 999,
      );
      expect(
        ImageInspector.verifyAsset(lyingSize).map((issue) => issue.message),
        contains(contains('Declared 999x999')),
      );
    });
  });
}
