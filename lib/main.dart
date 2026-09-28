import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lyberry/app.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/data/database_location.dart';
import 'package:lyberry/data/sqlite_media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/cover_downloader.dart';
import 'package:lyberry/services/api_transport.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/games/games_lookup_service.dart';
import 'package:lyberry/services/games/games_request_gate.dart';
import 'package:lyberry/services/games/games_transport.dart';
import 'package:lyberry/services/lookup_cache.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/movies/movies_lookup_service.dart';
import 'package:lyberry/services/movies/movies_request_gate.dart';
import 'package:lyberry/services/movies/movies_transport.dart';
import 'package:lyberry/services/photo_source.dart';
import 'package:lyberry/services/web/page_fetcher.dart';
import 'package:lyberry/services/web/web_lookup_service.dart';
import 'package:lyberry/services/providers/musicbrainz_provider.dart';
import 'package:lyberry/services/providers/open_library_provider.dart';
import 'package:lyberry/services/providers/upcitemdb_provider.dart';
import 'package:lyberry/services/rate_limiter.dart';
import 'package:lyberry/services/transport.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: LyberryColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  const clock = SystemClock();
  final repository = SqliteMediaRepository(
    factory: sqflite.databaseFactory,
    location: const DefaultDatabaseLocation(),
    clock: clock,
  );
  final transport = IoHttpTransport();
  // One cache instance for every provider, so a credential change can drop
  // stale game answers through the same object.
  final lookupCache = LookupCache(clock: clock);

  // One shared IGDB limiter/gate: barcode enrichment and title search share the
  // spacing, concurrency and cooldown state.
  final gamesLimiter = ProviderRateLimiter(
    providerId: GamesLookupService.providerId,
    minInterval: const Duration(milliseconds: 300),
    clock: clock,
  );
  final gamesGate = GamesRequestGate(limiter: gamesLimiter);

  // One shared UPCMDB limiter/gate: barcode identification and movie title
  // search share one local spacing, concurrency and 429 cooldown state, so the
  // app never spends two requests on one user action.
  final moviesLimiter = ProviderRateLimiter(
    providerId: MoviesLookupService.providerId,
    minInterval: MoviesEndpointLimits.minRequestInterval,
    clock: clock,
  );
  final moviesGate = MoviesRequestGate(limiter: moviesLimiter);

  final limiters = <String, ProviderRateLimiter>{
    // Open Library asks for roughly one request per second.
    'openlibrary': ProviderRateLimiter(
      providerId: 'openlibrary',
      minInterval: const Duration(milliseconds: 1000),
      clock: clock,
    ),
    // MusicBrainz asks for at most one request per second.
    'musicbrainz': ProviderRateLimiter(
      providerId: 'musicbrainz',
      minInterval: const Duration(milliseconds: 1100),
      clock: clock,
    ),
    // UPCitemdb free tier: 100 lookups/day, 6/minute, one per 10 seconds.
    'upcitemdb': ProviderRateLimiter(
      providerId: 'upcitemdb',
      minInterval: const Duration(seconds: 10),
      clock: clock,
    ),
    // IGDB asks for at most four requests per second; the shared gate keeps
    // barcode and title paths inside one budget and exposes the cooldown.
    'igdb': gamesLimiter,
    // UPCMDB is spaced to one request per second by the shared movies gate.
    MoviesLookupService.providerId: moviesLimiter,
  };

  final photoSource = ImagePickerPhotoSource();
  final keyStore = SecureApiKeyStore();
  final games = GamesLookupService(
    keys: keyStore,
    transport: IoGamesTransport(
      allowedEndpoints: GamesEndpoint.productionAllowlist,
    ),
    gate: gamesGate,
    cache: lookupCache,
    clock: clock,
  );
  final movies = MoviesLookupService(
    keys: keyStore,
    transport: IoMoviesTransport(
      allowedEndpoints: MoviesEndpoint.productionAllowlist,
    ),
    gate: moviesGate,
    cache: lookupCache,
  );

  final metadata = MetadataService(
    // Each provider throttles its own HTTP requests, so a provider that makes
    // two calls (Open Library) respects the spacing rule per call.
    providers: <MetadataProvider>[
      OpenLibraryProvider(
        transport: transport,
        limiter: limiters['openlibrary'],
        clock: clock,
      ),
      MusicBrainzProvider(
        transport: transport,
        limiter: limiters['musicbrainz'],
        clock: clock,
      ),
      UpcItemDbProvider(
        transport: transport,
        limiter: limiters['upcitemdb'],
        clock: clock,
      ),
      movies,
      games,
    ],
    limiters: limiters,
    cache: lookupCache,
  );

  final services = AppServices(
    repository: repository,
    metadata: metadata,
    covers: CoverDownloader(transport: transport),
    backup: BackupService(
      repository: repository,
      io: const FilePickerSnapshotIo(),
      clock: clock,
    ),
    photoSource: photoSource,
    keys: keyStore,
    games: games,
    movies: movies,
    webLookup: WebLookupService(
      keys: keyStore,
      transport: IoApiTransport(
        // Fixed production hosts only; the page fetcher has its own policy.
        allowedHosts: const <String>{'api.tavily.com', 'api.deepseek.com'},
      ),
      pages: SafePageFetcher(),
    ),
    clock: clock,
  );

  runApp(
    LyberryApp(
      controller: LibraryController(
        repository: repository,
        photoSource: photoSource,
        clock: clock,
      ),
      services: services,
    ),
  );
}
