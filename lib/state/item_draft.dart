import 'package:lyberry/domain/barcode.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/validation.dart';

/// Mutable editor state for one copy.
///
/// Text fields stay as the user typed them so the form can show a parse error
/// without losing input; [buildItem] converts them into a validated
/// [MediaItem] or throws a [ValidationException] listing every problem.
class ItemDraft {
  ItemDraft({
    required this.medium,
    required this.title,
    this.creator = '',
    this.publisher = '',
    this.description = '',
    this.platform = '',
    this.yearText = '',
    this.barcode = '',
    this.rating,
    this.review = '',
    this.notes = '',
    this.isFinished = false,
    this.coverAssetId,
    List<String>? photoAssetIds,
    this.source,
  }) : photoAssetIds = List<String>.of(photoAssetIds ?? const <String>[]);

  ItemDraft.fromItem(MediaItem item)
    : medium = item.medium,
      title = item.title,
      creator = item.creator,
      publisher = item.publisher,
      description = item.description,
      platform = item.platform,
      yearText = item.year?.toString() ?? '',
      barcode = item.barcode ?? '',
      rating = item.rating,
      review = item.review,
      notes = item.notes,
      isFinished = item.isFinished,
      coverAssetId = item.coverAssetId,
      photoAssetIds = List<String>.of(item.photoAssetIds),
      source = item.source;

  /// Prefills the editor from a chosen provider candidate; every field stays
  /// editable and nothing is saved until the user saves.
  ItemDraft.fromCandidate(MetadataCandidate candidate, {String? barcode})
    : medium = candidate.medium ?? MediaType.book,
      title = candidate.title,
      creator = candidate.creator,
      publisher = candidate.publisher,
      description = candidate.description,
      platform = candidate.platform,
      yearText = candidate.year?.toString() ?? '',
      barcode = barcode ?? '',
      rating = null,
      review = '',
      notes = '',
      isFinished = false,
      coverAssetId = null,
      photoAssetIds = <String>[],
      source = MediaSource(
        providerId: candidate.providerId,
        externalId: candidate.externalId,
        url: candidate.sourceUrl ?? '',
      );

  MediaType medium;
  String title;
  String creator;
  String publisher;
  String description;
  String platform;
  String yearText;
  String barcode;
  double? rating;
  String review;
  String notes;
  bool isFinished;
  String? coverAssetId;
  List<String> photoAssetIds;
  MediaSource? source;

  MediaItem buildItem({
    required String id,
    required String createdAt,
    required String updatedAt,
  }) {
    final issues = <ValidationIssue>[];
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      issues.add(const ValidationIssue('title', 'Title is required.'));
    }

    int? year;
    final yearInput = yearText.trim();
    if (yearInput.isNotEmpty) {
      year = int.tryParse(yearInput);
      if (year == null) {
        issues.add(const ValidationIssue('year', 'Year must be a number.'));
      } else if (year < FieldLimits.minYear || year > FieldLimits.maxYear) {
        issues.add(
          const ValidationIssue(
            'year',
            'Year must be between ${FieldLimits.minYear} and '
                '${FieldLimits.maxYear}.',
          ),
        );
      }
    }

    String? normalizedBarcode;
    final barcodeInput = barcode.trim();
    if (barcodeInput.isNotEmpty) {
      final problem = Barcode.describeProblem(barcodeInput);
      if (problem != null) {
        issues.add(ValidationIssue('barcode', problem));
      } else {
        normalizedBarcode = Barcode.normalize(barcodeInput);
      }
    }

    if (issues.isNotEmpty) throw ValidationException(issues);

    final item = MediaItem(
      id: id,
      medium: medium,
      title: trimmedTitle,
      creator: creator.trim(),
      publisher: publisher.trim(),
      description: description.trim(),
      platform: platform.trim(),
      year: year,
      barcode: normalizedBarcode,
      rating: rating,
      review: review.trim(),
      notes: notes.trim(),
      isFinished: isFinished,
      coverAssetId: coverAssetId,
      photoAssetIds: photoAssetIds,
      source: source,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
    ItemValidator.assertValid(item);
    return item;
  }
}
