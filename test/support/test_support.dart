import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lyberry/app.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/data/database_location.dart';
import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/data/sqlite_media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/ids.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/cover_downloader.dart';
import 'package:lyberry/services/api_transport.dart';
import 'package:lyberry/services/games/game_catalog.dart';
import 'package:lyberry/services/games/games_lookup_service.dart';
import 'package:lyberry/services/games/games_request_gate.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/movies/movie_catalog.dart';
import 'package:lyberry/services/movies/movies_lookup_service.dart';
import 'package:lyberry/services/movies/movies_request_gate.dart';
import 'package:lyberry/services/movies/movies_transport.dart';
import 'package:lyberry/services/photo_source.dart';
import 'package:lyberry/services/image_transform.dart';
import 'package:lyberry/services/web/page_fetcher.dart';
import 'package:lyberry/services/web/web_lookup_service.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_snapshot_io.dart';
import 'fake_games.dart';
import 'fake_movies.dart';
import 'fake_transport.dart';
import 'fake_web.dart';

/// Fixed wall clock used by every fixture: 2026-09-23T10:00:00Z.
final DateTime kBaseTime = DateTime.utc(2026, 9, 23, 10);
final String kBaseTimestamp = kBaseTime.toIso8601String();

/// Deterministic UUID v4 values so assertions can name exact identities.
class SequentialIdGenerator implements IdGenerator {
  int _counter = 0;

  @override
  String newId() {
    _counter++;
    return '00000000-0000-4000-8000-${_counter.toString().padLeft(12, '0')}';
  }
}

MediaItem sampleItem({
  required String id,
  MediaType medium = MediaType.book,
  String title = 'Dune',
  String creator = 'Frank Herbert',
  String publisher = 'Chilton',
  String description = '',
  String platform = '',
  int? year = 1965,
  String? barcode,
  double? rating,
  String review = '',
  String notes = '',
  bool isFinished = false,
  String? coverAssetId,
  List<String> photoAssetIds = const <String>[],
  MediaSource? source,
  String createdAt = '2026-09-23T10:00:00.000Z',
  String updatedAt = '2026-09-23T10:00:00.000Z',
}) {
  return MediaItem(
    id: id,
    medium: medium,
    title: title,
    creator: creator,
    publisher: publisher,
    description: description,
    platform: platform,
    year: year,
    barcode: barcode,
    rating: rating,
    review: review,
    notes: notes,
    isFinished: isFinished,
    coverAssetId: coverAssetId,
    photoAssetIds: photoAssetIds,
    source: source,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

Uint8List pngBytes({
  int width = 12,
  int height = 12,
  int red = 200,
  int green = 60,
  int blue = 50,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  return img.encodePng(image);
}

Uint8List jpegBytes({int width = 12, int height = 12}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(30, 40, 60));
  return img.encodeJpg(image);
}

/// A real, incompressible PNG comfortably larger than 2 MiB. Used by the
/// chunked BLOB tests so the Android cursor path is exercised with real data.
Uint8List largePngBytes({int size = 1000}) {
  final image = img.Image(width: size, height: size);
  final random = math.Random(7);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      image.setPixelRgb(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
  }
  return img.encodePng(image);
}

/// Poster-like cover art used by the render evidence, not by the app.
Uint8List posterBytes({
  required String title,
  required String caption,
  required int red,
  required int green,
  required int blue,
  int width = 600,
  int height = 900,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  // Horizon band plus a signal bar keeps the placeholder art geometric.
  img.fillRect(
    image,
    x1: 0,
    y1: (height * 0.62).round(),
    x2: width - 1,
    y2: height - 1,
    color: img.ColorRgb8(
      (red * 0.55).round(),
      (green * 0.55).round(),
      (blue * 0.55).round(),
    ),
  );
  img.fillRect(
    image,
    x1: 0,
    y1: (height * 0.62).round(),
    x2: width - 1,
    y2: (height * 0.62).round() + 6,
    color: img.ColorRgb8(242, 76, 62),
  );
  img.drawString(
    image,
    title,
    font: img.arial48,
    x: 40,
    y: (height * 0.72).round(),
    color: img.ColorRgb8(243, 244, 238),
  );
  img.drawString(
    image,
    caption,
    font: img.arial24,
    x: 42,
    y: (height * 0.72).round() + 60,
    color: img.ColorRgb8(200, 205, 208),
  );
  return img.encodeJpg(image, quality: 88);
}

class FakePhotoSource implements PhotoSource {
  FakePhotoSource({
    this.cameraBytes,
    this.libraryBytes,
    this.recovered = const <PickedPhoto>[],
    this.failure,
  });

  Uint8List? cameraBytes;
  Uint8List? libraryBytes;
  List<PickedPhoto> recovered;
  PhotoSourceFailure? failure;

  int cameraCalls = 0;
  int pickCalls = 0;

  @override
  Future<PickedPhoto?> capture() async {
    cameraCalls++;
    final problem = failure;
    if (problem != null) throw problem;
    final bytes = cameraBytes;
    return bytes == null
        ? null
        : PickedPhoto(bytes: bytes, sourceName: 'camera.jpg');
  }

  @override
  Future<PickedPhoto?> pick() async {
    pickCalls++;
    final problem = failure;
    if (problem != null) throw problem;
    final bytes = libraryBytes;
    return bytes == null
        ? null
        : PickedPhoto(bytes: bytes, sourceName: 'library.png');
  }

  @override
  Future<List<PickedPhoto>> recoverLostPhotos() async => recovered;
}

/// Loads the bundled Oxanium face plus the SDK's Roboto so rendered evidence
/// shows real glyphs instead of the test placeholder font.
Future<void> loadAppFonts() async {
  Future<ByteData> read(String path) async {
    final bytes = await File(path).readAsBytes();
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }

  final oxanium = FontLoader('Oxanium')
    ..addFont(read('assets/fonts/oxanium/Oxanium-Variable.ttf'));
  await oxanium.load();

  const materialFonts =
      '/Users/ghijs/development/flutter/bin/cache/artifacts/material_fonts';
  final icons = File('$materialFonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(read('$materialFonts/MaterialIcons-Regular.otf'));
    await loader.load();
  }
  final robotoRegular = File('$materialFonts/Roboto-Regular.ttf');
  if (!robotoRegular.existsSync()) return;
  for (final entry in <String, String>{
    'Roboto': 'Roboto-Regular.ttf',
    'RobotoMedium': 'Roboto-Medium.ttf',
    'RobotoBold': 'Roboto-Bold.ttf',
  }.entries) {
    final loader = FontLoader(entry.key)
      ..addFont(read('$materialFonts/${entry.value}'));
    await loader.load();
  }
}

/// Real SQLite (ffi) in a temp file, on the same code path as the app.
Future<SqliteMediaRepository> openTestRepository(
  String path, {
  IdGenerator? idGenerator,
  Clock? clock,
}) async {
  final repository = SqliteMediaRepository(
    factory: databaseFactoryFfi,
    location: FixedDatabaseLocation(path),
    idGenerator: idGenerator ?? SequentialIdGenerator(),
    clock: clock ?? FixedClock(kBaseTime),
  );
  await repository.initialize();
  return repository;
}

Directory createTempDir(String name) =>
    Directory.systemTemp.createTempSync('lyberry_$name');

LibraryController testController(
  MediaRepository repository, {
  PhotoSource? photoSource,
  Clock? clock,
  IdGenerator? idGenerator,
}) {
  return LibraryController(
    repository: repository,
    photoSource: photoSource,
    clock: clock ?? FixedClock(kBaseTime),
    idGenerator: idGenerator ?? SequentialIdGenerator(),
  );
}

Future<void> pumpApp(
  WidgetTester tester,
  LibraryController controller, {
  AppServices? services,
}) async {
  await tester.pumpWidget(
    LyberryApp(
      controller: controller,
      services: services ?? testServices(repository: controller.repository),
    ),
  );
  await tester.pump();
}

/// Service wiring for widget tests: no network, no file dialogs, no isolates,
/// and no metadata providers unless the test supplies its own service.
AppServices testServices({
  required MediaRepository repository,
  MetadataService? metadata,
  CoverDownloader? covers,
  BackupService? backup,
  PhotoSource? photoSource,
  ImageTransformService? images,
  Clock? clock,
  ApiKeyStore? keys,
  ApiTransport? apiTransport,
  PageFetcher? pages,
  WebLookupService? webLookup,
  GameCatalog? games,
  GamesTransport? gamesTransport,
  MovieCatalog? movies,
  MoviesTransport? moviesTransport,
  Duration webBudget = const Duration(seconds: 90),
}) {
  final resolvedClock = clock ?? FixedClock(kBaseTime);
  final transport = FakeHttpTransport();
  final resolvedKeys = keys ?? InMemoryApiKeyStore();
  return AppServices(
    repository: repository,
    metadata:
        metadata ??
        MetadataService(
          providers: const <MetadataProvider>[],
          cache: LookupCache(clock: resolvedClock),
        ),
    covers: covers ?? CoverDownloader(transport: transport),
    backup:
        backup ??
        BackupService(
          repository: repository,
          io: FakeSnapshotIo(),
          clock: resolvedClock,
          useIsolate: false,
        ),
    photoSource: photoSource ?? FakePhotoSource(),
    // Widget and golden tests run under fake async, so the pixel work runs on
    // the calling isolate; the service unit test covers the isolate worker.
    images:
        images ??
        const ImageTransformService(worker: InlineImageRenderWorker()),
    keys: resolvedKeys,
    games:
        games ??
        GamesLookupService(
          keys: resolvedKeys,
          transport: gamesTransport ?? FakeGamesTransport(),
          gate: GamesRequestGate(
            limiter: ProviderRateLimiter(
              providerId: GamesLookupService.providerId,
              minInterval: const Duration(milliseconds: 300),
              clock: resolvedClock,
            ),
          ),
          clock: resolvedClock,
        ),
    movies:
        movies ??
        MoviesLookupService(
          keys: resolvedKeys,
          transport: moviesTransport ?? FakeMoviesTransport(),
          gate: MoviesRequestGate(
            limiter: ProviderRateLimiter(
              providerId: MoviesLookupService.providerId,
              minInterval: const Duration(milliseconds: 10),
              clock: resolvedClock,
            ),
          ),
        ),
    webLookup:
        webLookup ??
        WebLookupService(
          keys: resolvedKeys,
          transport: apiTransport ?? FakeApiTransport(),
          pages: pages ?? FakePageFetcher(),
          budget: webBudget,
        ),
    clock: resolvedClock,
  );
}

/// Phone-sized surface with an optional text scale, like `flutter test --dpr`.
void useSurface(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
}

void resetSurface(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
}
