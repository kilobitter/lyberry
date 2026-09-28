import 'package:flutter/widgets.dart';
import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/cover_downloader.dart';
import 'package:lyberry/services/games/game_catalog.dart';
import 'package:lyberry/services/image_transform.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/movies/movie_catalog.dart';
import 'package:lyberry/services/photo_source.dart';
import 'package:lyberry/services/web/web_lookup_service.dart';

/// Everything the screens need that is not the library controller itself.
class AppServices {
  const AppServices({
    required this.repository,
    required this.metadata,
    required this.covers,
    required this.backup,
    required this.photoSource,
    required this.keys,
    required this.webLookup,
    required this.games,
    required this.movies,
    this.images = const ImageTransformService(),
    this.clock = const SystemClock(),
  });

  final MediaRepository repository;
  final MetadataService metadata;
  final CoverDownloader covers;
  final BackupService backup;
  final PhotoSource photoSource;

  /// Secure storage for the user's own Tavily and DeepSeek keys.
  final ApiKeyStore keys;

  /// Explicit, user-triggered web lookup. Never runs on its own.
  final WebLookupService webLookup;

  /// Explicit, user-triggered game title search (ScanDex + IGDB).
  final GameCatalog games;

  /// Explicit, user-triggered movie title search and barcode identification
  /// (UPCMDB).
  final MovieCatalog movies;

  /// Derived personal-photo covers: bounded, off-main decode/rotate/crop.
  final ImageTransformService images;
  final Clock clock;
}

class AppServicesScope extends InheritedWidget {
  const AppServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppServicesScope>();
    assert(scope != null, 'AppServicesScope is missing above this widget.');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppServicesScope oldWidget) =>
      oldWidget.services != services;
}
