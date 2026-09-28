import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/validation.dart';

/// Bounds applied before and during image decoding.
class ImageLimits {
  const ImageLimits({
    this.maxBytes = FieldLimits.maxAssetBytes,
    this.maxPixels = FieldLimits.maxAssetPixels,
  });

  final int maxBytes;
  final int maxPixels;
}

/// The safe facts extracted from raw image bytes.
class InspectedImage {
  const InspectedImage({
    required this.mimeType,
    required this.width,
    required this.height,
  });

  final String mimeType;
  final int width;
  final int height;
}

/// Header facts read before any pixel allocation.
class _Header {
  const _Header({
    required this.mimeType,
    required this.width,
    required this.height,
    this.isAnimated = false,
    this.isCanvas = false,
    this.bitstreamWidth,
    this.bitstreamHeight,
  });

  final String mimeType;
  final int width;
  final int height;
  final bool isAnimated;

  /// True when the dimensions are a container canvas rather than the bitstream
  /// itself (WebP VP8X).
  final bool isCanvas;

  /// Dimensions of the embedded image chunk, when the container has one.
  final int? bitstreamWidth;
  final int? bitstreamHeight;
}

/// Validates untrusted image bytes without ever allocating an unbounded raster.
///
/// Order of work: size check, container sniff, header dimension read, pixel
/// bound, animation rejection, and only then a single static decode that must
/// agree with the header. A compressed "pixel bomb" is rejected on its declared
/// dimensions instead of after a multi-gigabyte allocation.
abstract final class ImageInspector {
  /// A file with more header chunks than this is refused instead of assumed
  /// static. Real photos stay far below it.
  static const int _maxHeaderChunks = 1024;

  static InspectedImage inspect(
    Uint8List bytes, {
    ImageLimits limits = const ImageLimits(),
    String field = 'photo',
  }) {
    if (bytes.isEmpty) {
      throw ValidationException([
        ValidationIssue(field, 'The image file is empty.'),
      ]);
    }
    if (bytes.length > limits.maxBytes) {
      throw ValidationException([
        ValidationIssue(field, 'Images must be 5 MiB or smaller.'),
      ]);
    }

    final header = _readHeader(bytes, field);
    if (header.isAnimated) {
      throw ValidationException([
        ValidationIssue(field, 'Animated images are not supported.'),
      ]);
    }
    if (header.width <= 0 || header.height <= 0) {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    if (header.width * header.height > limits.maxPixels) {
      throw ValidationException([
        ValidationIssue(field, 'Images must be 20 megapixels or smaller.'),
      ]);
    }

    // The same decoder that will read pixels must agree, and its metadata is
    // authoritative: it is read before any raster is allocated.
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null || !_decoderMatches(decoder, header.mimeType)) {
      throw ValidationException([
        ValidationIssue(field, 'Use a JPEG, PNG or WebP image.'),
      ]);
    }

    final img.DecodeInfo? info;
    try {
      info = decoder.startDecode(bytes);
    } on Exception {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    if (info == null) {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    if (_isAnimated(info)) {
      throw ValidationException([
        ValidationIssue(field, 'Animated images are not supported.'),
      ]);
    }
    if (info.width <= 0 || info.height <= 0) {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    if (info.width * info.height > limits.maxPixels) {
      throw ValidationException([
        ValidationIssue(field, 'Images must be 20 megapixels or smaller.'),
      ]);
    }
    if (!_headerAgrees(header, info)) {
      throw ValidationException([
        ValidationIssue(
          field,
          'That image has conflicting header information and cannot be '
          'trusted.',
        ),
      ]);
    }
    if (header.isCanvas) {
      final bitstreamWidth = header.bitstreamWidth;
      final bitstreamHeight = header.bitstreamHeight;
      if (bitstreamWidth == null ||
          bitstreamHeight == null ||
          bitstreamWidth > info.width ||
          bitstreamHeight > info.height) {
        throw ValidationException([
          ValidationIssue(
            field,
            'That image has conflicting header information and cannot be '
            'trusted.',
          ),
        ]);
      }
    }

    // One explicit static frame only: the default PngDecoder path walks every
    // frame of an animated file.
    final img.Image? decoded;
    try {
      decoded = decoder.decode(bytes, frame: 0);
    } on Exception {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    if (decoded == null) {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    if (!_rasterAgrees(decoded, info, header, bytes)) {
      throw ValidationException([
        ValidationIssue(field, 'That image does not match its own metadata.'),
      ]);
    }

    return InspectedImage(
      mimeType: header.mimeType,
      width: info.width,
      height: info.height,
    );
  }

  /// The decoded raster must be the declared size or, for a JPEG whose own EXIF
  /// says the image is turned a quarter turn, its exact transpose.
  ///
  /// The installed JPEG decoder bakes the EXIF orientation and clears the tag
  /// before returning pixels, while [img.DecodeInfo] reports the un-rotated SOF
  /// size, so an honest portrait photo would otherwise look like a header that
  /// lies. The orientation is read from the file's own EXIF before any raster is
  /// used and only 5-8 (a 90 degree turn, with or without a mirror) is accepted,
  /// so the pixel count a file can claim is unchanged and every other
  /// disagreement - including a conflicting WebP canvas or PNG bitstream - still
  /// fails closed. [InspectedImage] keeps reporting the raw header dimensions,
  /// so stored-asset invariants do not move.
  static bool _rasterAgrees(
    img.Image decoded,
    img.DecodeInfo info,
    _Header header,
    Uint8List bytes,
  ) {
    if (decoded.width == info.width && decoded.height == info.height) {
      return true;
    }
    // Only JPEG carries the EXIF orientation this decoder bakes; PNG and WebP
    // keep the strict comparison.
    if (header.mimeType != AssetMime.jpeg) return false;
    final orientation = _jpegOrientation(bytes);
    if (orientation == null || orientation < 5 || orientation > 8) {
      return false;
    }
    return decoded.width == info.height && decoded.height == info.width;
  }

  /// The pre-decode EXIF orientation of a JPEG, or null when it has none.
  static int? _jpegOrientation(Uint8List bytes) {
    try {
      return img.decodeJpgExif(bytes)?.imageIfd.orientation;
    } on Object {
      return null;
    }
  }

  static bool _decoderMatches(img.Decoder decoder, String mimeType) =>
      switch (mimeType) {
        AssetMime.png => decoder is img.PngDecoder,
        AssetMime.jpeg => decoder is img.JpegDecoder,
        AssetMime.webp => decoder is img.WebPDecoder,
        _ => false,
      };

  static bool _isAnimated(img.DecodeInfo info) {
    if (info is img.PngInfo) return info.isAnimated || info.numFrames > 1;
    if (info is img.WebPInfo) {
      return info.hasAnimation || info.numFrames > 1;
    }
    return info.numFrames > 1;
  }

  /// Fail closed on any disagreement between the cheap first-header read and
  /// the decoder's authoritative metadata. A WebP canvas only counts when it
  /// matches the embedded bitstream, which [_readWebpHeader] already checked.
  static bool _headerAgrees(_Header header, img.DecodeInfo info) =>
      header.width == info.width && header.height == info.height;

  /// Checks that an asset's identity, MIME type and dimensions agree with its
  /// bytes.
  ///
  /// This is the single place that knows how to verify a stored image, so write
  /// boundaries call it once per new asset instead of each re-implementing it.
  static List<ValidationIssue> verifyAsset(
    MediaAsset asset, {
    String field = 'asset',
  }) {
    final issues = <ValidationIssue>[];

    final digest = sha256.convert(asset.bytes).toString();
    if (digest != asset.id) {
      issues.add(
        ValidationIssue(
          field,
          'Asset id does not match the SHA-256 of its bytes.',
        ),
      );
      return issues;
    }
    if (!AssetMime.isSupported(asset.mimeType)) {
      issues.add(ValidationIssue(field, 'Asset must be JPEG, PNG or WebP.'));
      return issues;
    }

    final InspectedImage inspected;
    try {
      inspected = inspect(asset.bytes, field: field);
    } on ValidationException catch (error) {
      issues.addAll(error.issues);
      return issues;
    }
    if (inspected.mimeType != asset.mimeType) {
      issues.add(
        ValidationIssue(
          field,
          'Declared ${asset.mimeType} but the bytes are ${inspected.mimeType}.',
        ),
      );
    }
    if (inspected.width != asset.width || inspected.height != asset.height) {
      issues.add(
        ValidationIssue(
          field,
          'Declared ${asset.width}x${asset.height} but the bytes are '
          '${inspected.width}x${inspected.height}.',
        ),
      );
    }
    return issues;
  }

  static _Header _readHeader(Uint8List bytes, String field) {
    if (_isPng(bytes)) return _readPngHeader(bytes, field);
    if (_isJpeg(bytes)) return _readJpegHeader(bytes, field);
    if (_isWebp(bytes)) return _readWebpHeader(bytes, field);
    throw ValidationException([
      ValidationIssue(field, 'Use a JPEG, PNG or WebP image.'),
    ]);
  }

  static bool _isPng(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A;

  static bool _isJpeg(Uint8List bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF;

  static bool _isWebp(Uint8List bytes) =>
      bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;

  static _Header _readPngHeader(Uint8List bytes, String field) {
    if (bytes.length < 24 || _ascii(bytes, 12, 4) != 'IHDR') {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    final width = _u32be(bytes, 16);
    final height = _u32be(bytes, 20);

    // Bounded and fail-closed: an exhausted budget or a truncated chunk list is
    // refused instead of being treated as a static image.
    var offset = 8;
    var chunks = 0;
    while (offset + 12 <= bytes.length) {
      if (chunks > _maxHeaderChunks) {
        throw ValidationException([
          ValidationIssue(
            field,
            'That image has too many header chunks to verify safely.',
          ),
        ]);
      }
      final type = _ascii(bytes, offset + 4, 4);
      // An acTL chunk means an animated PNG; Lyberry stores stills only.
      if (type == 'acTL') {
        return _Header(
          mimeType: AssetMime.png,
          width: width,
          height: height,
          isAnimated: true,
        );
      }
      if (type == 'IDAT' || type == 'IEND') {
        break;
      }
      final length = _u32be(bytes, offset);
      if (length < 0 || offset + 12 + length > bytes.length) break;
      offset += 12 + length;
      chunks++;
    }

    return _Header(mimeType: AssetMime.png, width: width, height: height);
  }

  static _Header _readJpegHeader(Uint8List bytes, String field) {
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = bytes[offset + 1];
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }
      if (marker == 0xD9) break;
      final length = _u16be(bytes, offset + 2);
      if (length < 2) break;
      final isStartOfFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isStartOfFrame) {
        if (offset + 9 > bytes.length) break;
        return _Header(
          mimeType: AssetMime.jpeg,
          width: _u16be(bytes, offset + 7),
          height: _u16be(bytes, offset + 5),
        );
      }
      offset += 2 + length;
    }
    throw ValidationException([
      ValidationIssue(field, 'That file could not be read as an image.'),
    ]);
  }

  static _Header _readWebpHeader(Uint8List bytes, String field) {
    if (bytes.length < 20) {
      throw ValidationException([
        ValidationIssue(field, 'That file could not be read as an image.'),
      ]);
    }
    switch (_ascii(bytes, 12, 4)) {
      case 'VP8X':
        if (bytes.length < 30) break;
        final flags = bytes[20];
        final canvasWidth = 1 + _u24le(bytes, 24);
        final canvasHeight = 1 + _u24le(bytes, 27);
        if (flags & 0x02 != 0) {
          // Animated WebP is refused before any bitstream walk.
          return _Header(
            mimeType: AssetMime.webp,
            width: canvasWidth,
            height: canvasHeight,
            isAnimated: true,
            isCanvas: true,
          );
        }
        final bitstream = _webpBitstreamDimensions(bytes);
        if (bitstream == null) break;
        if (bitstream.width > canvasWidth || bitstream.height > canvasHeight) {
          throw ValidationException([
            ValidationIssue(
              field,
              'That image has conflicting header information and cannot be '
              'trusted.',
            ),
          ]);
        }
        return _Header(
          mimeType: AssetMime.webp,
          width: canvasWidth,
          height: canvasHeight,
          isCanvas: true,
          bitstreamWidth: bitstream.width,
          bitstreamHeight: bitstream.height,
        );
      case 'VP8 ':
        if (bytes.length < 30 ||
            bytes[23] != 0x9D ||
            bytes[24] != 0x01 ||
            bytes[25] != 0x2A) {
          break;
        }
        return _Header(
          mimeType: AssetMime.webp,
          width: _u16le(bytes, 26) & 0x3FFF,
          height: _u16le(bytes, 28) & 0x3FFF,
        );
      case 'VP8L':
        if (bytes.length < 25 || bytes[20] != 0x2F) break;
        final bits = _u32le(bytes, 21);
        return _Header(
          mimeType: AssetMime.webp,
          width: (bits & 0x3FFF) + 1,
          height: ((bits >> 14) & 0x3FFF) + 1,
        );
    }
    throw ValidationException([
      ValidationIssue(field, 'That file could not be read as an image.'),
    ]);
  }

  /// Bounded RIFF walk for the embedded VP8/VP8L image chunk of a VP8X file.
  static ({int width, int height})? _webpBitstreamDimensions(Uint8List bytes) {
    var offset = 12;
    var chunks = 0;
    while (offset + 8 <= bytes.length && chunks < _maxHeaderChunks) {
      final type = _ascii(bytes, offset, 4);
      final size = _u32le(bytes, offset + 4);
      if (size < 0 || offset + 8 + size > bytes.length) return null;
      if (type == 'VP8 ' || type == 'VP8L') {
        final payload = Uint8List.sublistView(
          bytes,
          offset + 8,
          offset + 8 + size,
        );
        return _webpFrameDimensions(type, payload);
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
      chunks++;
    }
    return null;
  }

  static ({int width, int height})? _webpFrameDimensions(
    String type,
    Uint8List payload,
  ) {
    if (type == 'VP8 ') {
      if (payload.length < 10 ||
          payload[3] != 0x9D ||
          payload[4] != 0x01 ||
          payload[5] != 0x2A) {
        return null;
      }
      return (
        width: _u16le(payload, 6) & 0x3FFF,
        height: _u16le(payload, 8) & 0x3FFF,
      );
    }
    if (payload.length < 5 || payload[0] != 0x2F) return null;
    final bits = _u32le(payload, 1);
    return (width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1);
  }

  static String _ascii(Uint8List bytes, int offset, int length) {
    final buffer = StringBuffer();
    for (var index = offset; index < offset + length; index++) {
      if (index >= bytes.length) break;
      buffer.writeCharCode(bytes[index]);
    }
    return buffer.toString();
  }

  static int _u16be(Uint8List bytes, int offset) =>
      (bytes[offset] << 8) | bytes[offset + 1];

  static int _u16le(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _u24le(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

  static int _u32be(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _u32le(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
