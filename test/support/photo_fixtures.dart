import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A four-quadrant photo: red top-left, green top-right, blue bottom-left,
/// yellow bottom-right. Asymmetric in both axes, so a wrong crop edge or a
/// wrong rotation shows up immediately as the wrong colour.
///
/// With [orientation] set, the JPEG header stays [width] x [height] and carries
/// the EXIF tag, exactly like a camera photo that has not been re-encoded.
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

img.Image decodeBytes(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) throw StateError('fixture did not decode');
  return image;
}

({int r, int g, int b}) pixelAt(img.Image image, int x, int y) {
  final pixel = image.getPixel(x, y);
  return (r: pixel.r.toInt(), g: pixel.g.toInt(), b: pixel.b.toInt());
}

bool isNearColour(
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

/// The declared (un-baked) JPEG size, before any decoder applies the EXIF tag.
({int width, int height}) declaredSize(Uint8List bytes) {
  final info = img.findDecoderForData(bytes)!.startDecode(bytes)!;
  return (width: info.width, height: info.height);
}

/// The EXIF orientation tag straight out of the APP1 segment.
int? exifOrientation(Uint8List bytes) {
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
    final tiff = index + 10;
    if (marker == 0xE1 &&
        _isExifMarker(bytes, index + 4) &&
        tiff + 8 < bytes.length) {
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
    index += 2 + length;
  }
  return null;
}

bool _isExifMarker(Uint8List bytes, int at) =>
    at + 4 <= bytes.length &&
    bytes[at] == 0x45 &&
    bytes[at + 1] == 0x78 &&
    bytes[at + 2] == 0x69 &&
    bytes[at + 3] == 0x66;
