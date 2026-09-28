import 'package:lyberry/domain/barcode.dart';
import 'package:lyberry/domain/ids.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/timestamps.dart';

/// A single field-level problem, ready to show next to the offending input.
class ValidationIssue {
  const ValidationIssue(this.field, this.message);

  final String field;
  final String message;

  @override
  String toString() => '$field: $message';
}

/// Raised when user input or stored data violates the domain contract.
class ValidationException implements Exception {
  const ValidationException(this.issues);

  final List<ValidationIssue> issues;

  String get message => issues.map((issue) => issue.message).join('\n');

  @override
  String toString() => 'ValidationException: $message';
}

/// Half-star rating rules shared by the editor, the repository and backups.
abstract final class RatingRules {
  static const double min = 0.5;
  static const double max = 5.0;

  static bool isValid(double? value) {
    if (value == null) return true;
    if (value.isNaN || value.isInfinite) return false;
    if (value < min || value > max) return false;
    return (value * 2).roundToDouble() == value * 2;
  }

  /// Snaps a drag/tap position onto the nearest half star, clamped to 0..5.
  static double? snap(double? value) {
    if (value == null) return null;
    if (value <= 0) return null;
    final snapped = (value * 2).round() / 2;
    if (snapped < min) return min;
    if (snapped > max) return max;
    return snapped;
  }

  static String format(double? value) =>
      value == null ? 'Unrated' : value.toStringAsFixed(1);
}

/// Domain limits; single source of truth for editors, storage and backups.
abstract final class FieldLimits {
  static const int title = 500;
  static const int shortText = 1000;
  static const int longText = 20000;
  static const int maxPhotos = 20;
  static const int minYear = 1;
  static const int maxYear = 9999;
  static const int maxAssetBytes = 5 * 1024 * 1024;
  static const int maxAssetPixels = 20 * 1000 * 1000;
}

/// Validates a [MediaItem] against the stable domain contract.
abstract final class ItemValidator {
  static List<ValidationIssue> validate(MediaItem item) {
    final issues = <ValidationIssue>[];

    if (!isUuidV4(item.id)) {
      issues.add(
        const ValidationIssue('id', 'Item identity must be a UUID v4.'),
      );
    }

    final title = item.title.trim();
    if (title.isEmpty) {
      issues.add(const ValidationIssue('title', 'Title is required.'));
    } else if (title.length > FieldLimits.title) {
      issues.add(
        const ValidationIssue(
          'title',
          'Title must be ${FieldLimits.title} characters or fewer.',
        ),
      );
    }

    if (item.creator.length > FieldLimits.shortText) {
      issues.add(
        const ValidationIssue(
          'creator',
          'Creator must be ${FieldLimits.shortText} characters or fewer.',
        ),
      );
    }
    if (item.publisher.length > FieldLimits.shortText) {
      issues.add(
        const ValidationIssue(
          'publisher',
          'Publisher must be ${FieldLimits.shortText} characters or fewer.',
        ),
      );
    }
    if (item.platform.length > FieldLimits.shortText) {
      issues.add(
        const ValidationIssue(
          'platform',
          'Platform must be ${FieldLimits.shortText} characters or fewer.',
        ),
      );
    }
    if (item.description.length > FieldLimits.longText) {
      issues.add(
        const ValidationIssue(
          'description',
          'Description must be ${FieldLimits.longText} characters or fewer.',
        ),
      );
    }
    if (item.review.length > FieldLimits.longText) {
      issues.add(
        const ValidationIssue(
          'review',
          'Review must be ${FieldLimits.longText} characters or fewer.',
        ),
      );
    }
    if (item.notes.length > FieldLimits.longText) {
      issues.add(
        const ValidationIssue(
          'notes',
          'Notes must be ${FieldLimits.longText} characters or fewer.',
        ),
      );
    }

    final year = item.year;
    if (year != null &&
        (year < FieldLimits.minYear || year > FieldLimits.maxYear)) {
      issues.add(
        const ValidationIssue(
          'year',
          'Year must be between ${FieldLimits.minYear} and ${FieldLimits.maxYear}.',
        ),
      );
    }

    if (!RatingRules.isValid(item.rating)) {
      issues.add(
        const ValidationIssue(
          'rating',
          'Rating must be half-star steps from 0.5 to 5.0.',
        ),
      );
    }

    final barcode = item.barcode;
    if (barcode != null) {
      if (barcode != barcode.trim() || !Barcode.isValid(barcode)) {
        issues.add(
          const ValidationIssue(
            'barcode',
            'Barcode/ISBN must be a valid ISBN-10, ISBN-13, EAN-13, EAN-8 or UPC-A.',
          ),
        );
      }
    }

    final coverId = item.coverAssetId;
    if (coverId != null && !isSha256Hex(coverId)) {
      issues.add(
        const ValidationIssue(
          'coverAssetId',
          'Cover reference is not a SHA-256 id.',
        ),
      );
    }

    if (item.photoAssetIds.length > FieldLimits.maxPhotos) {
      issues.add(
        const ValidationIssue(
          'photoAssetIds',
          'A copy can hold at most ${FieldLimits.maxPhotos} photos.',
        ),
      );
    }
    final seen = <String>{};
    for (final photoId in item.photoAssetIds) {
      if (!isSha256Hex(photoId)) {
        issues.add(
          const ValidationIssue(
            'photoAssetIds',
            'Photo reference is not a SHA-256 id.',
          ),
        );
        break;
      }
      if (!seen.add(photoId)) {
        issues.add(
          const ValidationIssue(
            'photoAssetIds',
            'Photo references must be unique.',
          ),
        );
        break;
      }
    }

    final source = item.source;
    if (source != null) {
      if (source.providerId.trim().isEmpty) {
        issues.add(
          const ValidationIssue(
            'source.providerId',
            'Source provider is required.',
          ),
        );
      }
      if (source.externalId.trim().isEmpty) {
        issues.add(
          const ValidationIssue(
            'source.externalId',
            'Source record id is required.',
          ),
        );
      }
      if (source.url.isNotEmpty) {
        final uri = Uri.tryParse(source.url);
        if (uri == null || uri.scheme != 'https' || !uri.hasAuthority) {
          issues.add(
            const ValidationIssue(
              'source.url',
              'Source URL must be an absolute https URL.',
            ),
          );
        }
      }
    }

    if (!isCanonicalTimestamp(item.createdAt)) {
      issues.add(
        const ValidationIssue(
          'createdAt',
          'Created timestamp must be canonical UTC ISO-8601.',
        ),
      );
    }
    if (!isCanonicalTimestamp(item.updatedAt)) {
      issues.add(
        const ValidationIssue(
          'updatedAt',
          'Updated timestamp must be canonical UTC ISO-8601.',
        ),
      );
    }

    return issues;
  }

  static void assertValid(MediaItem item) {
    final issues = validate(item);
    if (issues.isNotEmpty) throw ValidationException(issues);
  }

  static List<ValidationIssue> validateAsset(MediaAsset asset) {
    final issues = <ValidationIssue>[];
    if (!isSha256Hex(asset.id)) {
      issues.add(
        const ValidationIssue('id', 'Asset id must be a lowercase SHA-256.'),
      );
    }
    if (!AssetMime.isSupported(asset.mimeType)) {
      issues.add(
        const ValidationIssue('mimeType', 'Asset must be JPEG, PNG or WebP.'),
      );
    }
    if (asset.bytes.isEmpty) {
      issues.add(const ValidationIssue('bytes', 'Asset is empty.'));
    } else if (asset.byteSize > FieldLimits.maxAssetBytes) {
      issues.add(
        const ValidationIssue('bytes', 'Images must be 5 MiB or smaller.'),
      );
    }
    if (asset.width <= 0 || asset.height <= 0) {
      issues.add(
        const ValidationIssue('bytes', 'Asset dimensions are invalid.'),
      );
    } else if (asset.width * asset.height > FieldLimits.maxAssetPixels) {
      issues.add(
        const ValidationIssue(
          'bytes',
          'Images must be 20 megapixels or smaller.',
        ),
      );
    }
    return issues;
  }
}

/// Validates a raw barcode string, returning the normalized value or throwing.
String? normalizeBarcodeOrThrow(String raw) {
  final problem = Barcode.describeProblem(raw);
  if (problem != null) {
    throw ValidationException([ValidationIssue('barcode', problem)]);
  }
  return Barcode.normalize(raw);
}
