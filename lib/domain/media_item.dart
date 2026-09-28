import 'package:lyberry/domain/collection_utils.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/timestamps.dart';

/// Optional metadata provenance. Never used as an item identity.
class MediaSource {
  const MediaSource({
    required this.providerId,
    required this.externalId,
    this.url = '',
  });

  final String providerId;
  final String externalId;
  final String url;

  Map<String, Object?> toJson() => <String, Object?>{
    'providerId': providerId,
    'externalId': externalId,
    'url': url,
  };

  /// Strict decode for backups: a malformed block is an error, never silently
  /// dropped.
  static MediaSource fromJson(Map<Object?, Object?> json) {
    final providerId = json['providerId'];
    final externalId = json['externalId'];
    if (providerId is! String || providerId.trim().isEmpty) {
      throw const FormatException(
        'source.providerId must be a non-empty string.',
      );
    }
    if (externalId is! String || externalId.trim().isEmpty) {
      throw const FormatException(
        'source.externalId must be a non-empty string.',
      );
    }
    final url = json['url'];
    if (url != null && url is! String) {
      throw const FormatException('source.url must be a string.');
    }
    if (providerId.length > 1000 || externalId.length > 1000) {
      throw const FormatException('source identifiers are too long.');
    }
    final urlText = url is String ? url : '';
    if (urlText.length > 2000) {
      throw const FormatException('source.url is too long.');
    }
    return MediaSource(
      providerId: providerId,
      externalId: externalId,
      url: urlText,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaSource &&
      other.providerId == providerId &&
      other.externalId == externalId &&
      other.url == url;

  @override
  int get hashCode => Object.hash(providerId, externalId, url);

  @override
  String toString() => 'MediaSource($providerId, $externalId)';
}

/// One owned physical copy.
///
/// Identity is [id] alone: two copies of the same barcode are two items. All
/// fields are immutable; use [copyWith] to derive a changed value.
class MediaItem {
  MediaItem({
    required this.id,
    required this.medium,
    required this.title,
    this.creator = '',
    this.publisher = '',
    this.description = '',
    this.platform = '',
    this.year,
    this.barcode,
    this.rating,
    this.review = '',
    this.notes = '',
    this.isFinished = false,
    this.coverAssetId,
    List<String> photoAssetIds = const <String>[],
    this.source,
    required this.createdAt,
    required this.updatedAt,
  }) : photoAssetIds = List<String>.unmodifiable(photoAssetIds);

  final String id;
  final MediaType medium;
  final String title;
  final String creator;
  final String publisher;
  final String description;
  final String platform;
  final int? year;
  final String? barcode;
  final double? rating;
  final String review;
  final String notes;

  /// Whether the owner has finished this copy. Personal, per-copy data; the UI
  /// only offers it for books and films, but every record can store it.
  final bool isFinished;
  final String? coverAssetId;
  final List<String> photoAssetIds;
  final MediaSource? source;
  final String createdAt;
  final String updatedAt;

  DateTime get createdDateTime => decodeTimestamp(createdAt);

  DateTime get updatedDateTime => decodeTimestamp(updatedAt);

  /// Fields shown under the title in the collection grid.
  String get byline => creator.trim().isEmpty
      ? medium.label
      : '${creator.trim()} | ${medium.label}';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'medium': medium.wireValue,
    'title': title,
    'creator': creator,
    'publisher': publisher,
    'description': description,
    'platform': platform,
    'year': year,
    'barcode': barcode,
    'rating': rating,
    'review': review,
    'notes': notes,
    'isFinished': isFinished,
    'coverAssetId': coverAssetId,
    'photoAssetIds': List<String>.of(photoAssetIds),
    'source': source?.toJson(),
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  static const Object _unset = Object();

  /// Strict decode for storage and backup payloads.
  ///
  /// Type errors throw [FormatException]; semantic bounds are checked
  /// separately by the validator so callers can report every problem at once.
  static MediaItem fromJson(Map<String, Object?> json) {
    T require<T>(String key) {
      final value = json[key];
      if (value is! T) {
        throw FormatException('Field "$key" must be a $T.');
      }
      return value;
    }

    String? requireNullableString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('Field "$key" must be a string or null.');
      }
      return value;
    }

    final rawMedium = json['medium'];
    final medium = MediaType.tryParse(rawMedium);
    if (medium == null) {
      throw FormatException('Field "medium" has an unknown value: $rawMedium');
    }

    final rawYear = json['year'];
    if (rawYear != null && rawYear is! int) {
      throw const FormatException('Field "year" must be an integer or null.');
    }

    final rawRating = json['rating'];
    if (rawRating != null && rawRating is! num) {
      throw const FormatException('Field "rating" must be a number or null.');
    }

    final rawFinished = json['isFinished'];
    // Absence is the legacy case (schema 1 predates the field); a *present*
    // value must be a boolean, including rejecting an explicit null.
    final hasFinished = json.containsKey('isFinished');
    if (hasFinished && rawFinished is! bool) {
      throw const FormatException('Field "isFinished" must be a boolean.');
    }

    final rawPhotos = json['photoAssetIds'];
    if (rawPhotos is! List) {
      throw const FormatException('Field "photoAssetIds" must be a list.');
    }
    final photos = <String>[];
    for (final photo in rawPhotos) {
      if (photo is! String) {
        throw const FormatException('Photo ids must be strings.');
      }
      photos.add(photo);
    }

    final rawSource = json['source'];
    if (rawSource != null && rawSource is! Map) {
      throw const FormatException('Field "source" must be an object or null.');
    }

    return MediaItem(
      id: require<String>('id'),
      medium: medium,
      title: require<String>('title'),
      creator: require<String>('creator'),
      publisher: require<String>('publisher'),
      description: require<String>('description'),
      platform: require<String>('platform'),
      year: rawYear as int?,
      barcode: requireNullableString('barcode'),
      rating: rawRating == null ? null : (rawRating as num).toDouble(),
      review: require<String>('review'),
      notes: require<String>('notes'),
      // Absent means "not finished": legacy payloads predate the field.
      isFinished: rawFinished == true,
      coverAssetId: requireNullableString('coverAssetId'),
      photoAssetIds: photos,
      source: rawSource == null
          ? null
          : MediaSource.fromJson(rawSource as Map<Object?, Object?>),
      createdAt: require<String>('createdAt'),
      updatedAt: require<String>('updatedAt'),
    );
  }

  MediaItem copyWith({
    MediaType? medium,
    String? title,
    String? creator,
    String? publisher,
    String? description,
    String? platform,
    Object? year = _unset,
    Object? barcode = _unset,
    Object? rating = _unset,
    String? review,
    String? notes,
    bool? isFinished,
    Object? coverAssetId = _unset,
    List<String>? photoAssetIds,
    Object? source = _unset,
    String? createdAt,
    String? updatedAt,
  }) {
    return MediaItem(
      id: id,
      medium: medium ?? this.medium,
      title: title ?? this.title,
      creator: creator ?? this.creator,
      publisher: publisher ?? this.publisher,
      description: description ?? this.description,
      platform: platform ?? this.platform,
      year: identical(year, _unset) ? this.year : year as int?,
      barcode: identical(barcode, _unset) ? this.barcode : barcode as String?,
      rating: identical(rating, _unset) ? this.rating : rating as double?,
      review: review ?? this.review,
      notes: notes ?? this.notes,
      isFinished: isFinished ?? this.isFinished,
      coverAssetId: identical(coverAssetId, _unset)
          ? this.coverAssetId
          : coverAssetId as String?,
      photoAssetIds: photoAssetIds ?? this.photoAssetIds,
      source: identical(source, _unset) ? this.source : source as MediaSource?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MediaItem &&
        other.id == id &&
        other.medium == medium &&
        other.title == title &&
        other.creator == creator &&
        other.publisher == publisher &&
        other.description == description &&
        other.platform == platform &&
        other.year == year &&
        other.barcode == barcode &&
        other.rating == rating &&
        other.review == review &&
        other.notes == notes &&
        other.isFinished == isFinished &&
        other.coverAssetId == coverAssetId &&
        orderedListEquals<String>(other.photoAssetIds, photoAssetIds) &&
        other.source == source &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    medium,
    title,
    creator,
    publisher,
    description,
    platform,
    year,
    barcode,
    rating,
    review,
    notes,
    isFinished,
    coverAssetId,
    orderedListHash<String>(photoAssetIds),
    source,
    createdAt,
    updatedAt,
  );

  @override
  String toString() => 'MediaItem($id, ${medium.wireValue}, "$title")';
}
