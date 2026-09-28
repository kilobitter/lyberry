import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/ids.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/timestamps.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:lyberry/services/photo_source.dart';
import 'package:lyberry/state/item_draft.dart';

enum LibraryStatus { starting, ready, failed }

enum PhotoOrigin { camera, library }

/// UI state for the collection, backed by an injected [MediaRepository].
class LibraryController extends ChangeNotifier {
  LibraryController({
    required MediaRepository repository,
    IdGenerator? idGenerator,
    Clock? clock,
    ImageIngest? imageIngest,
    PhotoSource? photoSource,
  }) : _repository = repository,
       _idGenerator = idGenerator ?? UuidV4IdGenerator(),
       _clock = clock ?? const SystemClock(),
       _imageIngest = imageIngest ?? const ImageIngest(),
       _photoSource = photoSource;

  final MediaRepository _repository;
  final IdGenerator _idGenerator;
  final Clock _clock;
  final ImageIngest _imageIngest;
  final PhotoSource? _photoSource;

  LibraryStatus _status = LibraryStatus.starting;
  String? _failureMessage;
  List<MediaItem> _items = const <MediaItem>[];
  int _totalCount = 0;
  String _search = '';
  MediaType? _mediumFilter;

  /// Selected game platform, or `null` for "All platforms".
  String? _platformFilter;
  List<String> _availableGamePlatforms = const <String>[];
  String? _recoveryNotice;
  int _loadToken = 0;
  bool _disposed = false;
  Future<void>? _startInFlight;

  /// Bounded LRU so scrolling a large library never retains every original
  /// image in memory.
  static const int assetCacheLimit = 32;
  final LinkedHashMap<String, Future<MediaAsset?>> _assetCache =
      LinkedHashMap<String, Future<MediaAsset?>>();
  final List<PickedPhoto> _recoveredPhotos = <PickedPhoto>[];

  LibraryStatus get status => _status;
  MediaRepository get repository => _repository;
  String? get failureMessage => _failureMessage;
  List<MediaItem> get items => List<MediaItem>.unmodifiable(_items);
  int get totalCount => _totalCount;
  String get search => _search;
  MediaType? get mediumFilter => _mediumFilter;

  /// Selected platform when [mediumFilter] is [MediaType.game], else `null`.
  String? get platformFilter => _platformFilter;

  /// Every named platform that exists on a saved game, sorted and deduplicated.
  List<String> get availableGamePlatforms => _availableGamePlatforms;

  bool get hasFilters =>
      _search.trim().isNotEmpty ||
      _mediumFilter != null ||
      _platformFilter != null;

  /// Message about photos recovered from a previous session, or `null`.
  String? takeRecoveryNotice() {
    final notice = _recoveryNotice;
    _recoveryNotice = null;
    return notice;
  }

  /// Opens the store, loads the collection and recovers Android lost photos.
  Future<void> start({bool force = false}) {
    if (!force) {
      final inFlight = _startInFlight;
      if (inFlight != null) return inFlight;
      if (_status == LibraryStatus.ready) return Future<void>.value();
    }
    final future = _runStart();
    _startInFlight = future.whenComplete(() => _startInFlight = null);
    return _startInFlight!;
  }

  Future<void> _runStart() async {
    _failureMessage = null;
    _setStatus(LibraryStatus.starting);
    try {
      await _repository.initialize();
      await _reload();
      _setStatus(LibraryStatus.ready);
    } on Object catch (error) {
      _failureMessage = describeFailure(error);
      _setStatus(LibraryStatus.failed);
      return;
    }
    await _recoverLostPhotos();
  }

  Future<void> retry() => start(force: true);

  Future<void> refresh() async {
    try {
      await _reload();
      if (_status != LibraryStatus.ready) _setStatus(LibraryStatus.ready);
    } on Object catch (error) {
      _failureMessage = describeFailure(error);
      _setStatus(LibraryStatus.failed);
    }
  }

  Future<void> setSearch(String value) async {
    if (_search == value) return;
    _search = value;
    notifyListeners();
    await refresh();
  }

  Future<void> setMediumFilter(MediaType? value) async {
    if (_mediumFilter == value) return;
    _mediumFilter = value;
    // Leaving Games drops the platform predicate.
    if (value != MediaType.game) _platformFilter = null;
    notifyListeners();
    await refresh();
  }

  /// Selects one game platform, or `All platforms` when [value] is null or no
  /// longer available. Unknown or blank values fall back to All.
  Future<void> setPlatformFilter(String? value) async {
    final next = _resolvePlatformOption(value);
    if (_platformFilter == next) return;
    _platformFilter = next;
    notifyListeners();
    await refresh();
  }

  Future<void> clearFilters() async {
    if (!hasFilters) return;
    _search = '';
    _mediumFilter = null;
    _platformFilter = null;
    notifyListeners();
    await refresh();
  }

  Future<MediaItem?> item(String id) => _repository.getItem(id);

  /// Cached image lookup so grid tiles do not re-read blobs on every rebuild.
  Future<MediaAsset?> asset(String id) {
    final cached = _assetCache.remove(id);
    if (cached != null) {
      _assetCache[id] = cached;
      return cached;
    }
    final future = _repository.getAsset(id);
    _assetCache[id] = future;
    while (_assetCache.length > assetCacheLimit) {
      _assetCache.remove(_assetCache.keys.first);
    }
    return future;
  }

  int get assetCacheLength => _assetCache.length;

  Future<MediaItem> createItem(
    ItemDraft draft, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async {
    final now = encodeTimestamp(_clock.nowUtc());
    final item = draft.buildItem(
      id: _idGenerator.newId(),
      createdAt: now,
      updatedAt: now,
    );
    await _repository.createItem(item, assets: assets);
    await refresh();
    return item;
  }

  Future<MediaItem> updateItem(
    MediaItem existing,
    ItemDraft draft, {
    List<MediaAsset> assets = const <MediaAsset>[],
  }) async {
    final item = draft.buildItem(
      id: existing.id,
      createdAt: existing.createdAt,
      updatedAt: encodeTimestamp(_clock.nowUtc()),
    );
    await _repository.updateItem(item, assets: assets);
    await refresh();
    return item;
  }

  Future<MediaItem> addCopy(String id) async {
    final copy = await _repository.createCopy(id);
    await refresh();
    return copy;
  }

  Future<void> deleteItem(String id) async {
    await _repository.deleteItem(id);
    await refresh();
  }

  /// Returns `null` when the user cancels the camera or picker.
  Future<MediaAsset?> capturePhoto(PhotoOrigin origin) async {
    final source = _photoSource;
    if (source == null) {
      throw const PhotoSourceFailure('Photos are unavailable on this device.');
    }
    final picked = origin == PhotoOrigin.camera
        ? await source.capture()
        : await source.pick();
    if (picked == null) return null;
    return _imageIngest.buildAsset(picked.bytes);
  }

  Future<void> _reload() async {
    final token = ++_loadToken;
    // Captured for this reload: a stale completion must never overwrite a
    // newer search, medium or platform choice.
    final requestedMedium = _mediumFilter;
    final requestedSearch = _search;
    final requestedPlatform = _platformFilter;
    final items = await _repository.listItems(
      medium: requestedMedium,
      query: requestedSearch,
    );
    final total = await _repository.countItems();
    // Options come from every saved game, independent of the text query and of
    // the current platform selection.
    final List<String> platforms;
    if (requestedMedium == MediaType.game) {
      final games = await _repository.listItems(medium: MediaType.game);
      platforms = _platformsFrom(games);
    } else {
      platforms = const <String>[];
    }
    if (token != _loadToken || _disposed) return;

    // Resolve the captured selection onto the exact spelling of the refreshed
    // options. A casing/whitespace-only change keeps the logical filter alive,
    // but a vanished platform falls back to All in this same reload so the grid
    // never shows a stale filter. Publishing the resolved string also keeps the
    // value identical (`==`) to a dropdown item, whose lookup is exact.
    final selected = requestedMedium == MediaType.game
        ? _resolvedOption(platforms, requestedPlatform)
        : null;
    _platformFilter = selected;
    _availableGamePlatforms = platforms;
    _items = _filterByPlatform(items, selected);
    _totalCount = total;
    notifyListeners();
  }

  /// Readable platform options from [games]: blank names skipped, whitespace
  /// collapsed, deduplicated case-insensitively, sorted case-insensitively.
  static List<String> _platformsFrom(List<MediaItem> games) {
    final byKey = <String, String>{};
    for (final game in games) {
      if (game.medium != MediaType.game) continue;
      final display = _collapseSpaces(game.platform);
      if (display.isEmpty) continue;
      final key = display.toLowerCase();
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = display;
        continue;
      }
      // A shouted or lowercased duplicate must not win over a properly cased
      // spelling of the same platform.
      if (_caseScore(display) > _caseScore(existing)) byKey[key] = display;
    }
    final values = byKey.values.toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return List<String>.unmodifiable(values);
  }

  /// Readability rank used only to pick between case-insensitive duplicates:
  /// a mixed-case spelling beats an all-upper one, which beats an all-lower.
  /// Legitimate abbreviations keep their stored spelling; nothing here rewrites
  /// [MediaItem.platform].
  static int _caseScore(String value) {
    var hasUpper = false;
    var hasLower = false;
    for (final rune in value.runes) {
      if (rune >= 0x41 && rune <= 0x5a) {
        hasUpper = true;
      } else if (rune >= 0x61 && rune <= 0x7a) {
        hasLower = true;
      }
    }
    if (hasUpper && hasLower) return 2;
    if (hasUpper) return 1;
    return 0;
  }

  /// Maps a requested value onto a stored option; blank/unknown becomes All.
  String? _resolvePlatformOption(String? value) =>
      _resolvedOption(_availableGamePlatforms, value);

  /// The exact option from [options] that matches [value] case-insensitively
  /// and ignoring repeated whitespace, or `null` when there is none.
  static String? _resolvedOption(List<String> options, String? value) {
    if (value == null) return null;
    final wanted = _collapseSpaces(value).toLowerCase();
    if (wanted.isEmpty) return null;
    for (final option in options) {
      if (_collapseSpaces(option).toLowerCase() == wanted) return option;
    }
    return null;
  }

  /// Applies the platform predicate to already filtered game rows.
  static List<MediaItem> _filterByPlatform(
    List<MediaItem> items,
    String? platform,
  ) {
    if (platform == null) return items;
    final wanted = _collapseSpaces(platform).toLowerCase();
    return <MediaItem>[
      for (final item in items)
        if (item.medium == MediaType.game &&
            _collapseSpaces(item.platform).toLowerCase() == wanted)
          item,
    ];
  }

  static String _collapseSpaces(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  Future<void> _recoverLostPhotos() async {
    final source = _photoSource;
    if (source == null) return;
    try {
      final recovered = await source.recoverLostPhotos();
      if (recovered.isEmpty || _disposed) return;
      _recoveredPhotos
        ..clear()
        ..addAll(recovered);
      _recoveryNotice =
          'Recovered ${recovered.length} photo(s) from the last session. '
          'They appear in the next editor you open.';
      notifyListeners();
    } on Object catch (error) {
      _recoveryNotice =
          'A photo from the last session could not be recovered: '
          '${describeFailure(error)}';
      notifyListeners();
    }
  }

  /// Photos recovered from a killed Android session, consumed by the editor.
  List<PickedPhoto> takeRecoveredPhotos() {
    if (_recoveredPhotos.isEmpty) return const <PickedPhoto>[];
    final photos = List<PickedPhoto>.of(_recoveredPhotos);
    _recoveredPhotos.clear();
    return photos;
  }

  MediaAsset buildPhotoAsset(PickedPhoto photo) =>
      _imageIngest.buildAsset(photo.bytes);

  void _setStatus(LibraryStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Turns storage and validation failures into one user-facing sentence.
String describeFailure(Object error) {
  if (error is StorageFailure) return error.message;
  if (error is ValidationException) return error.message;
  if (error is PhotoSourceFailure) return error.message;
  if (error is ItemNotFoundFailure) {
    return 'That copy is no longer in your library.';
  }
  return 'Something went wrong: $error';
}
