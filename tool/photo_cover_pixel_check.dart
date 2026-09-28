// Real-pixel checks for the personal-photo cover pipeline.
//
// Runs the exact code the app's isolate worker runs (`CoverRenderer`), so this
// is the same decode / EXIF-orient / quarter-turn / crop / bound / strip /
// encode path. It needs no Flutter engine, only the cached Dart SDK:
//
//   /Users/ghijs/development/flutter/bin/cache/dart-sdk/bin/dart \
//     --suppress-analytics run tool/photo_cover_pixel_check.dart
//
// Exit code 0 means every check passed; 1 lists the failures.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/cover_renderer.dart';
import 'package:lyberry/domain/image_inspector.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/validation.dart';

int _checks = 0;
final List<String> _failures = <String>[];

void check(bool ok, String what) {
  _checks++;
  if (!ok) _failures.add(what);
  report(ok ? '  PASS  $what' : '  FAIL  $what');
}

void report(String line) {
  // ignore: avoid_print
  print(line);
}

void checkEq(Object? actual, Object? expected, String what) {
  check(actual == expected, '$what (expected $expected, got $actual)');
}

void checkNear(num actual, num expected, num tolerance, String what) {
  check(
    (actual - expected).abs() <= tolerance,
    '$what (expected $expected +/- $tolerance, got $actual)',
  );
}

/// A four-quadrant image: red top-left, green top-right, blue bottom-left,
/// yellow bottom-right. Asymmetric in both axes, so a wrong rotation or a
/// wrong crop edge shows up as the wrong colour.
Uint8List quadJpeg({
  int width = 240,
  int height = 120,
  int orientation = 0,
  int quality = 96,
}) {
  final image = img.Image(width: width, height: height);
  final halfWidth = width ~/ 2;
  final halfHeight = height ~/ 2;
  img.fill(image, color: img.ColorRgb8(12, 12, 12));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: halfWidth - 1,
    y2: halfHeight - 1,
    color: img.ColorRgb8(220, 30, 30),
  );
  img.fillRect(
    image,
    x1: halfWidth,
    y1: 0,
    x2: width - 1,
    y2: halfHeight - 1,
    color: img.ColorRgb8(30, 200, 30),
  );
  img.fillRect(
    image,
    x1: 0,
    y1: halfHeight,
    x2: halfWidth - 1,
    y2: height - 1,
    color: img.ColorRgb8(30, 30, 220),
  );
  img.fillRect(
    image,
    x1: halfWidth,
    y1: halfHeight,
    x2: width - 1,
    y2: height - 1,
    color: img.ColorRgb8(230, 210, 40),
  );
  if (orientation != 0) image.exif.imageIfd.orientation = orientation;
  return img.encodeJpg(image, quality: quality);
}

img.Image decode(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) throw StateError('fixture did not decode');
  return image;
}

/// A small opaque PNG, used by the container-level negative fixtures.
Uint8List quadPng({int width = 8, int height = 8}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(40, 80, 120));
  return img.encodePng(image);
}

({int r, int g, int b}) pixelAt(img.Image image, int x, int y) {
  final pixel = image.getPixel(x, y);
  return (r: pixel.r.toInt(), g: pixel.g.toInt(), b: pixel.b.toInt());
}

bool isNear(
  ({int r, int g, int b}) colour,
  int r,
  int g,
  int b, {
  int tolerance = 34,
}) {
  return (colour.r - r).abs() <= tolerance &&
      (colour.g - g).abs() <= tolerance &&
      (colour.b - b).abs() <= tolerance;
}

String describe(({int r, int g, int b}) colour) =>
    'rgb(${colour.r},${colour.g},${colour.b})';

void main() {
  report('photo-cover pixel checks (CoverRenderer)');

  _cropValidation();
  _fullFrameRoundTrip();
  _cropAffectsSavedPixels();
  _quarterTurns();
  _exifOrientation();
  _exifCropMapping();
  _outputBounds();
  _metadataStripped();
  _assetValidation();
  _deterministicIdentity();
  _previewMatchesOutputSpace();
  _canonicalExifIngest();
  _canonicalSafetyGuards();
  _rejectsOversizedSource();

  report('');
  report('checks: $_checks, failures: ${_failures.length}');
  for (final failure in _failures) {
    report('  FAILED: $failure');
  }
  if (_failures.isNotEmpty) {
    throw StateError('${_failures.length} check(s) failed');
  }
  report('all photo-cover pixel checks passed');
}

void _cropValidation() {
  report('crop validation');
  check(
    const CoverCrop(
      left: 0.5,
      top: 0,
      width: 0.5,
      height: 1,
      quarterTurns: 3,
    ).validate().isEmpty,
    'a half-frame crop with a quarter turn is valid',
  );
  check(
    const CoverCrop(width: 0).validate().isNotEmpty,
    'an empty crop is rejected',
  );
  check(
    const CoverCrop(left: 0.8, width: 0.4).validate().isNotEmpty,
    'a crop past the right edge is rejected',
  );
  check(
    const CoverCrop(top: -0.2).validate().isNotEmpty,
    'a crop above the top edge is rejected',
  );
  check(
    const CoverCrop(
      width: double.nan,
      height: double.infinity,
    ).validate().isNotEmpty,
    'non-finite crop values are rejected',
  );
  check(
    const CoverCrop(quarterTurns: 4).validate().isNotEmpty,
    'an out-of-range quarter turn is rejected',
  );

  var threw = false;
  try {
    CoverRenderer.renderCover(
      source: quadJpeg(),
      crop: const CoverCrop(width: 0),
    );
  } on ValidationException {
    threw = true;
  }
  check(threw, 'rendering an empty crop throws instead of encoding');

  final pixels = const CoverCrop(
    left: 0.5,
    width: 0.5,
  ).toPixels(imageWidth: 240, imageHeight: 120);
  checkEq(pixels.x, 120, 'pixel mapping starts at the half width');
  checkEq(pixels.width, 120, 'pixel mapping spans the half width');
}

void _fullFrameRoundTrip() {
  report('full-frame round trip');
  final source = quadJpeg();
  final rendered = CoverRenderer.renderCover(
    source: source,
    crop: CoverCrop.full,
  );
  final decoded = decode(rendered);
  checkEq(decoded.width, 240, 'full-frame cover keeps the width');
  checkEq(decoded.height, 120, 'full-frame cover keeps the height');
  check(
    isNear(pixelAt(decoded, 60, 30), 220, 30, 30),
    'top-left quadrant survives (${describe(pixelAt(decoded, 60, 30))})',
  );
  check(
    isNear(pixelAt(decoded, 180, 30), 30, 200, 30),
    'top-right quadrant survives (${describe(pixelAt(decoded, 180, 30))})',
  );
  check(
    isNear(pixelAt(decoded, 60, 90), 30, 30, 220),
    'bottom-left quadrant survives (${describe(pixelAt(decoded, 60, 90))})',
  );
  check(
    isNear(pixelAt(decoded, 180, 90), 230, 210, 40),
    'bottom-right quadrant survives (${describe(pixelAt(decoded, 180, 90))})',
  );
}

void _cropAffectsSavedPixels() {
  report('crop changes saved pixels');
  final source = quadJpeg();
  final rightHalf = CoverRenderer.renderCover(
    source: source,
    crop: const CoverCrop(left: 0.5, top: 0, width: 0.5, height: 1),
  );
  final decoded = decode(rightHalf);
  checkEq(decoded.width, 120, 'right half is half as wide');
  checkEq(decoded.height, 120, 'right half keeps the height');
  check(
    isNear(pixelAt(decoded, 30, 30), 30, 200, 30),
    'right half starts on the green quadrant (${describe(pixelAt(decoded, 30, 30))})',
  );
  check(
    isNear(pixelAt(decoded, 90, 90), 230, 210, 40),
    'right half ends on the yellow quadrant (${describe(pixelAt(decoded, 90, 90))})',
  );

  // The same rectangle dragged to a corner must produce different bytes.
  final bottomLeft = CoverRenderer.renderCover(
    source: source,
    crop: const CoverCrop(left: 0, top: 0.5, width: 0.5, height: 0.5),
  );
  check(
    img.decodeImage(bottomLeft)!.width == 120 &&
        isNear(pixelAt(decode(bottomLeft), 60, 30), 30, 30, 220),
    'a corner drag changes the saved slice (${describe(pixelAt(decode(bottomLeft), 60, 30))})',
  );
}

void _quarterTurns() {
  report('quarter turns');
  final source = quadJpeg();
  final clockwise = decode(
    CoverRenderer.renderCover(
      source: source,
      crop: const CoverCrop(quarterTurns: 1),
    ),
  );
  checkEq(clockwise.width, 120, 'one clockwise turn swaps the width');
  checkEq(clockwise.height, 240, 'one clockwise turn swaps the height');
  // Clockwise: the old bottom-left corner lands top-left.
  check(
    isNear(pixelAt(clockwise, 30, 60), 30, 30, 220),
    'clockwise puts the old bottom-left top-left (${describe(pixelAt(clockwise, 30, 60))})',
  );
  check(
    isNear(pixelAt(clockwise, 90, 180), 30, 200, 30),
    'clockwise puts the old top-right bottom-right (${describe(pixelAt(clockwise, 90, 180))})',
  );

  final anticlockwise = decode(
    CoverRenderer.renderCover(
      source: source,
      crop: const CoverCrop(quarterTurns: 3),
    ),
  );
  checkEq(anticlockwise.width, 120, 'three clockwise turns swap the width');
  check(
    isNear(pixelAt(anticlockwise, 30, 60), 30, 200, 30),
    'anticlockwise puts the old top-right top-left (${describe(pixelAt(anticlockwise, 30, 60))})',
  );

  final half = decode(
    CoverRenderer.renderCover(
      source: source,
      crop: const CoverCrop(quarterTurns: 2),
    ),
  );
  checkEq(half.width, 240, 'a half turn keeps the width');
  check(
    isNear(pixelAt(half, 60, 30), 230, 210, 40),
    'a half turn puts the old bottom-right top-left (${describe(pixelAt(half, 60, 30))})',
  );
}

void _exifOrientation() {
  report('EXIF orientation');
  final landscape = quadJpeg(orientation: 6);
  final declared = img.findDecoderForData(landscape)!.startDecode(landscape)!;
  checkEq(declared.width, 240, 'the encoded header stays landscape wide');
  checkEq(declared.height, 120, 'the encoded header stays landscape high');
  checkEq(
    _exifOrientationOf(landscape),
    6,
    'the fixture declares EXIF orientation 6',
  );

  final preview = CoverRenderer.preparePreview(source: landscape);
  checkEq(
    preview.width,
    120,
    'the preview bakes orientation into a portrait width',
  );
  checkEq(
    preview.height,
    240,
    'the preview bakes orientation into a portrait height',
  );
  final previewPixels = decode(preview.bytes);
  check(
    isNear(pixelAt(previewPixels, 30, 60), 30, 30, 220),
    'orientation 6 turns the old bottom-left top-left (${describe(pixelAt(previewPixels, 30, 60))})',
  );

  final cover = decode(
    CoverRenderer.renderCover(source: landscape, crop: CoverCrop.full),
  );
  checkEq(cover.width, 120, 'the saved cover is portrait too');
  checkEq(cover.height, 240, 'the saved cover keeps the oriented height');
  check(
    isNear(pixelAt(cover, 30, 60), 30, 30, 220),
    'the saved cover matches the preview corner (${describe(pixelAt(cover, 30, 60))})',
  );
  check(
    isNear(pixelAt(cover, 90, 180), 30, 200, 30),
    'the saved cover matches the far preview corner (${describe(pixelAt(cover, 90, 180))})',
  );
  checkEqualGrid(
    previewPixels,
    cover,
    'preview and output agree pixel for pixel',
  );
}

/// Compares the two images on a coarse grid, tolerating JPEG re-encode noise.
void checkEqualGrid(img.Image a, img.Image b, String what) {
  if (a.width != b.width || a.height != b.height) {
    check(
      false,
      '$what (sizes ${a.width}x${a.height} vs ${b.width}x${b.height})',
    );
    return;
  }
  var mismatches = 0;
  for (var y = 8; y < a.height; y += 24) {
    for (var x = 8; x < a.width; x += 24) {
      final left = pixelAt(a, x, y);
      final right = pixelAt(b, x, y);
      if (!isNear(left, right.r, right.g, right.b, tolerance: 40)) mismatches++;
    }
  }
  check(mismatches == 0, '$what (mismatches: $mismatches)');
}

void _exifCropMapping() {
  report('crop maps in oriented space');
  final landscape = quadJpeg(orientation: 6);
  // The oriented image is 120x240: the old bottom-left quadrant is now
  // top-left, the old top-left quadrant is now top-right.
  final topHalf = decode(
    CoverRenderer.renderCover(
      source: landscape,
      crop: const CoverCrop(left: 0, top: 0, width: 1, height: 0.5),
    ),
  );
  checkEq(topHalf.width, 120, 'the oriented crop keeps the oriented width');
  checkEq(
    topHalf.height,
    120,
    'the oriented crop takes half the oriented height',
  );
  check(
    isNear(pixelAt(topHalf, 30, 60), 30, 30, 220),
    'oriented top-left is the old bottom-left (${describe(pixelAt(topHalf, 30, 60))})',
  );
  check(
    isNear(pixelAt(topHalf, 90, 60), 220, 30, 30),
    'oriented top-right is the old top-left (${describe(pixelAt(topHalf, 90, 60))})',
  );

  // A quarter turn on top of the EXIF bake: 120x240 -> 240x120.
  final turned = decode(
    CoverRenderer.renderCover(
      source: landscape,
      crop: const CoverCrop(quarterTurns: 1),
    ),
  );
  checkEq(turned.width, 240, 'EXIF plus a quarter turn is landscape again');
  checkEq(turned.height, 120, 'EXIF plus a quarter turn keeps the height');
  check(
    isNear(pixelAt(turned, 60, 30), 230, 210, 40),
    'the rotated oriented image starts on the old bottom-right (${describe(pixelAt(turned, 60, 30))})',
  );
}

void _outputBounds() {
  report('output bounds');
  final big = quadJpeg(width: 3200, height: 2400, quality: 70);
  final rendered = CoverRenderer.renderCover(source: big, crop: CoverCrop.full);
  final decoded = decode(rendered);
  checkEq(decoded.width, 2560, 'a 3200px source is bounded to 2560 wide');
  checkEq(decoded.height, 1920, 'the aspect ratio is preserved at the bound');
  check(
    rendered.length <= FieldLimits.maxAssetBytes,
    'the bounded cover stays under the 5 MiB asset cap (${rendered.length} bytes)',
  );

  final small = decode(
    CoverRenderer.renderCover(
      source: quadJpeg(width: 200, height: 400),
      crop: CoverCrop.full,
    ),
  );
  checkEq(small.width, 200, 'a small source is not upscaled');
  checkEq(small.height, 400, 'a small source keeps its height');
}

void _metadataStripped() {
  report('metadata stripped');
  final source = quadJpeg(orientation: 6);
  check(_hasExifApp1(source), 'the fixture really carries an APP1 EXIF block');
  final rendered = CoverRenderer.renderCover(
    source: source,
    crop: CoverCrop.full,
  );
  check(
    !_hasExifApp1(rendered),
    'the derived cover carries no EXIF APP1 block',
  );
  final decoded = decode(rendered);
  check(
    !decoded.exif.imageIfd.hasOrientation,
    'the derived cover has no orientation tag left',
  );
  check(decoded.exif.isEmpty, 'the derived cover EXIF block is empty');

  final preview = CoverRenderer.preparePreview(source: source);
  check(
    !_hasExifApp1(preview.bytes),
    'the interactive preview is metadata-free too',
  );
}

bool _hasExifApp1(Uint8List bytes) {
  for (var index = 0; index + 6 <= bytes.length; index++) {
    if (bytes[index] == 0x45 &&
        bytes[index + 1] == 0x78 &&
        bytes[index + 2] == 0x69 &&
        bytes[index + 3] == 0x66) {
      return true;
    }
  }
  return false;
}

/// Reads the EXIF orientation tag straight out of the APP1 segment, which is
/// what the file declares before any decoder bakes it into the raster.
int? _exifOrientationOf(Uint8List bytes) {
  var index = 2;
  while (index + 4 < bytes.length) {
    if (bytes[index] != 0xFF) {
      index++;
      continue;
    }
    final marker = bytes[index + 1];
    if (marker == 0xDA) return null;
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      index += 2;
      continue;
    }
    final length = (bytes[index + 2] << 8) | bytes[index + 3];
    if (marker == 0xE1) {
      final tiff = index + 10;
      if (_startsWithExif(bytes, index + 4) && tiff + 8 < bytes.length) {
        final littleEndian = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
        int u16(int at) => littleEndian
            ? bytes[at] | (bytes[at + 1] << 8)
            : (bytes[at] << 8) | bytes[at + 1];
        int u32(int at) => littleEndian
            ? bytes[at] |
                  (bytes[at + 1] << 8) |
                  (bytes[at + 2] << 16) |
                  (bytes[at + 3] << 24)
            : (bytes[at] << 24) |
                  (bytes[at + 1] << 16) |
                  (bytes[at + 2] << 8) |
                  bytes[at + 3];
        final ifd = tiff + u32(tiff + 4);
        final entries = u16(ifd);
        for (var entry = 0; entry < entries; entry++) {
          final at = ifd + 2 + entry * 12;
          if (at + 12 > bytes.length) break;
          if (u16(at) == 0x0112) return u16(at + 8);
        }
      }
    }
    index += 2 + length;
  }
  return null;
}

bool _startsWithExif(Uint8List bytes, int at) =>
    at + 4 <= bytes.length &&
    bytes[at] == 0x45 &&
    bytes[at + 1] == 0x78 &&
    bytes[at + 2] == 0x69 &&
    bytes[at + 3] == 0x66;

void _assetValidation() {
  report('derived asset validation');
  final rendered = CoverRenderer.renderCover(
    source: quadJpeg(),
    crop: const CoverCrop(left: 0.25, top: 0.25, width: 0.5, height: 0.5),
  );
  final asset = MediaAsset.fromBytes(rendered, field: 'cover');
  checkEq(asset.mimeType, AssetMime.jpeg, 'the derived cover is a JPEG');
  final decoded = decode(rendered);
  checkEq(asset.width, decoded.width, 'the asset width matches its bytes');
  checkEq(asset.height, decoded.height, 'the asset height matches its bytes');
  check(
    asset.bytes.length == rendered.length,
    'the asset keeps the encoded bytes',
  );
}

void _deterministicIdentity() {
  report('deterministic identity');
  final source = quadJpeg();
  const crop = CoverCrop(left: 0.1, top: 0.2, width: 0.6, height: 0.7);
  final first = CoverRenderer.renderCover(source: source, crop: crop);
  final second = CoverRenderer.renderCover(source: source, crop: crop);
  checkEq(
    MediaAsset.fromBytes(first).id,
    MediaAsset.fromBytes(second).id,
    'the same crop of the same original derives the same cover id',
  );
  final other = CoverRenderer.renderCover(
    source: source,
    crop: crop.copyWith(width: 0.5),
  );
  check(
    MediaAsset.fromBytes(first).id != MediaAsset.fromBytes(other).id,
    'a different crop derives a different cover id',
  );
}

void _previewMatchesOutputSpace() {
  report('preview matches output space');
  final source = quadJpeg(width: 400, height: 200);
  final oriented = CoverRenderer.preparePreview(source: source);
  checkEq(oriented.width, 400, 'a preview under the cap keeps its width');
  checkEq(oriented.height, 200, 'a preview under the cap keeps its height');

  final rotated = CoverRenderer.rotatePreview(
    preview: oriented.bytes,
    quarterTurns: 1,
  );
  checkEq(rotated.width, 200, 'a rotated preview swaps the width');
  checkEq(rotated.height, 400, 'a rotated preview swaps the height');
  final rotatedPixels = decode(rotated.bytes);
  check(
    isNear(pixelAt(rotatedPixels, 50, 100), 30, 30, 220),
    'the rotated preview shows the old bottom-left top-left (${describe(pixelAt(rotatedPixels, 50, 100))})',
  );

  final cover = decode(
    CoverRenderer.renderCover(
      source: source,
      crop: const CoverCrop(quarterTurns: 1),
    ),
  );
  checkEqualGrid(rotatedPixels, cover, 'rotated preview and output agree');
}

/// Every orientation an honest camera JPEG can carry must be ingestible as a
/// stored photo, and the crop pipeline must render the oriented image.
void _canonicalExifIngest() {
  report('canonical EXIF ingest, orientations 1-8');
  for (final orientation in <int>[1, 2, 3, 4, 5, 6, 7, 8]) {
    final bytes = quadJpeg(orientation: orientation);
    final declared = img.findDecoderForData(bytes)!.startDecode(bytes)!;
    final swaps = orientation >= 5;

    MediaAsset asset;
    try {
      asset = MediaAsset.fromBytes(bytes, field: 'photo');
    } on ValidationException catch (error) {
      check(
        false,
        'orientation $orientation ingests (${error.issues.first.message})',
      );
      continue;
    }
    check(
      asset.contentVerified,
      'orientation $orientation ingests as a verified asset',
    );
    checkEq(
      asset.id,
      sha256.convert(bytes).toString(),
      'orientation $orientation keeps its content address',
    );
    checkEq(
      asset.width,
      declared.width,
      'orientation $orientation keeps the raw stored width',
    );
    checkEq(
      asset.height,
      declared.height,
      'orientation $orientation keeps the raw stored height',
    );

    final decoded = img.decodeImage(bytes)!;
    checkEq(
      decoded.width,
      swaps ? declared.height : declared.width,
      'orientation $orientation decodes at the baked width',
    );
    checkEq(
      decoded.height,
      swaps ? declared.width : declared.height,
      'orientation $orientation decodes at the baked height',
    );

    final cover = CoverRenderer.deriveCoverAsset(
      source: bytes,
      crop: CoverCrop.full,
    );
    checkEq(
      cover.width,
      decoded.width,
      'orientation $orientation cover follows the oriented width',
    );
    checkEq(
      cover.height,
      decoded.height,
      'orientation $orientation cover follows the oriented height',
    );
  }
}

/// The canonical inspector must keep failing closed everywhere the new EXIF
/// allowance does not apply.
void _canonicalSafetyGuards() {
  report('canonical safety guards still fail closed');
  check(
    _inspectRejects(jpegDeclaringSize(30000, 30000), 'megapixel'),
    'a JPEG pixel bomb is refused from its frame header',
  );
  check(
    _inspectRejects(pngWithConflictingHeader(16, 16), ''),
    'a conflicting duplicate PNG header is refused',
  );
  check(
    _inspectRejects(animatedPngBytes(), 'Animated'),
    'an animated PNG is refused',
  );
  check(
    _inspectRejects(
      pngWithAncillaryChunksThenAnimation(1200),
      'too many header chunks',
    ),
    'a PNG chunk pile is refused instead of assumed static',
  );
  check(
    _inspectRejects(animatedWebpBytes(), 'Animated'),
    'an animated WebP is refused',
  );
  check(
    _inspectRejects(webpWithCanvas(4, 4), 'conflicting header information'),
    'a WebP canvas below its bitstream is refused',
  );
  check(
    _inspectRejects(webpWithCanvas(60000, 60000), 'megapixel'),
    'a WebP canvas bomb is refused',
  );
  check(
    ImageInspector.inspect(quadJpeg()).mimeType == AssetMime.jpeg,
    'a plain orientation-free JPEG still inspects as JPEG',
  );
}

bool _inspectRejects(Uint8List bytes, String needle) {
  try {
    ImageInspector.inspect(bytes, field: 'photo');
    return false;
  } on ValidationException catch (error) {
    if (needle.isEmpty) return true;
    return error.issues.any((issue) => issue.message.contains(needle));
  }
}

/// Reveals oversized dimensions in the JPEG frame header while keeping the
/// payload tiny.
Uint8List jpegDeclaringSize(int width, int height) {
  final bytes = Uint8List.fromList(quadJpeg(width: 8, height: 8));
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

Uint8List pngWithConflictingHeader(int width, int height) {
  final base = quadPng(width: 8, height: 8);
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

List<int> _pngChunk(String type, List<int> data) {
  final length = <int>[
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
  ];
  return <int>[...length, ...type.codeUnits, ...data, 0, 0, 0, 0];
}

Uint8List animatedPngBytes() {
  final base = quadPng(width: 8, height: 8);
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

Uint8List pngWithAncillaryChunksThenAnimation(int ancillary) {
  final base = quadPng(width: 8, height: 8);
  final ihdr = base.sublist(8, 33);
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

/// Wraps the real VP8 bitstream in `webp-sample.webp` in a VP8X container with
/// the given canvas, so the canvas can be made to disagree with the bitstream.
Uint8List webpWithCanvas(int canvasWidth, int canvasHeight) {
  final fixture = _webpFixture();
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

Uint8List _webpFixture() => File('test/fixtures/sample.webp').readAsBytesSync();

void _rejectsOversizedSource() {
  report('rejects oversized and animated sources');
  // The declared-dimension bound is what matters: a tight limit refuses the
  // same 28 800-pixel fixture that the real 20 MP default accepts.
  final fixture = quadJpeg(width: 240, height: 120);
  var threw = false;
  try {
    CoverRenderer.renderCover(
      source: fixture,
      crop: CoverCrop.full,
      limits: const ImageLimits(maxPixels: 1000),
    );
  } on ValidationException catch (error) {
    threw = error.issues.any((issue) => issue.message.contains('megapixels'));
  }
  check(threw, 'a source over the pixel bound is refused before raster work');

  var previewThrew = false;
  try {
    CoverRenderer.preparePreview(
      source: fixture,
      limits: const ImageLimits(maxBytes: 32),
    );
  } on ValidationException catch (error) {
    previewThrew = error.issues.any((issue) => issue.message.contains('5 MiB'));
  }
  check(previewThrew, 'a source over the byte bound is refused');

  final notAnImage = Uint8List.fromList(List<int>.filled(64, 7));
  var textThrew = false;
  try {
    CoverRenderer.preparePreview(source: notAnImage);
  } on ValidationException {
    textThrew = true;
  }
  check(textThrew, 'non-image bytes are refused with a validation error');

  check(
    ImageLimits().maxPixels == FieldLimits.maxAssetPixels &&
        FieldLimits.maxAssetPixels == 20 * 1000 * 1000 &&
        FieldLimits.maxAssetBytes == 5 * 1024 * 1024,
    'the inspector bounds are still the shared 5 MiB / 20 MP limits',
  );
}
