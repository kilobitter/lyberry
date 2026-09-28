import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/state/lookup_controller.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/screens/merge_preview_screen.dart';
import 'package:lyberry/ui/screens/scan_screen.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../support/fake_scan_camera.dart';
import '../support/fake_snapshot_io.dart';
import '../support/in_memory_repository.dart';
import '../support/stub_provider.dart';
import '../support/test_support.dart';

// Renders the P2 flows (candidates, merge preview, settings) for review.
// Run with: flutter test --update-goldens test/golden/p2_render_evidence_test.dart
void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  MetadataService stubMetadata() => MetadataService(
    providers: <MetadataProvider>[
      StubMetadataProvider(
        id: 'openlibrary',
        label: 'Open Library',
        candidates: <MetadataCandidate>[
          stubCandidate(
            providerId: 'openlibrary',
            providerLabel: 'Open Library',
            externalId: '/books/OL1M',
            title: 'Dune',
            creator: 'Frank Herbert',
            year: 1974,
          ),
          stubCandidate(
            providerId: 'openlibrary',
            providerLabel: 'Open Library',
            externalId: '/works/OL1W',
            title: 'Dune (work)',
            creator: 'Frank Herbert',
            year: null,
            matchKind: MatchKind.possible,
          ),
        ],
      ),
      StubMetadataProvider(
        id: 'upcitemdb',
        label: 'UPCitemdb',
        candidates: <MetadataCandidate>[
          stubCandidate(
            providerId: 'upcitemdb',
            providerLabel: 'UPCitemdb',
            externalId: '5051892202657',
            title: 'Dune (Blu-ray)',
            creator: 'Warner Bros.',
            year: null,
            medium: null,
            matchKind: MatchKind.possible,
          ),
        ],
      ),
    ],
  );

  Future<LibraryController> seededController(
    InMemoryMediaRepository repository,
  ) async {
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Dune',
        creator: 'Frank Herbert',
        rating: 4.5,
        createdAt: '2026-09-23T10:00:00.000Z',
        updatedAt: '2026-09-23T10:00:00.000Z',
      ),
    );
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000002',
        medium: MediaType.vinyl,
        title: 'Mezzanine',
        creator: 'Massive Attack',
        rating: 5.0,
        createdAt: '2026-09-23T11:00:00.000Z',
        updatedAt: '2026-09-23T11:00:00.000Z',
      ),
    );
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    return controller;
  }

  testWidgets('candidates at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await seededController(repository);
    final metadata = stubMetadata();
    final services = testServices(repository: repository, metadata: metadata);

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();

    final lookup = LookupController(
      service: metadata,
      query: LookupQuery(
        identifier: IdentifierNormalizer.normalize('9780306406157'),
      ),
    );
    addTearDown(lookup.dispose);
    await lookup.search(lookup.query!);

    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CandidatesScreen(query: lookup.query!, controller: lookup),
          ),
        );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/p2_candidates_390x844.png'),
    );
  });

  testWidgets('candidates at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await seededController(repository);
    final metadata = stubMetadata();
    final services = testServices(repository: repository, metadata: metadata);

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();

    final lookup = LookupController(
      service: metadata,
      query: LookupQuery(
        identifier: IdentifierNormalizer.normalize('9780306406157'),
      ),
    );
    addTearDown(lookup.dispose);
    await lookup.search(lookup.query!);

    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CandidatesScreen(query: lookup.query!, controller: lookup),
          ),
        );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/p2_candidates_320x568_scale1.6.png'),
    );
  });

  testWidgets('merge preview at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));

    // Export two copies from one library, then preview them into a library that
    // already holds one of them.
    final source = InMemoryMediaRepository();
    await seededController(source);
    final sourceIo = FakeSnapshotIo();
    await BackupService(
      repository: source,
      io: sourceIo,
      clock: FixedClock(kBaseTime),
      useIsolate: false,
    ).export();

    final target = InMemoryMediaRepository();
    await target.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Dune (older local)',
        createdAt: '2026-09-23T10:00:00.000Z',
        updatedAt: '2026-09-23T10:00:00.000Z',
      ),
    );
    final targetIo = FakeSnapshotIo(
      pickResult: PickedBackup(
        fileName: 'lyberry-20260923-101500.lyberry.json',
        contents: sourceIo.savedContents!,
        byteLength: sourceIo.savedContents!.length,
      ),
    );
    final backup = BackupService(
      repository: target,
      io: targetIo,
      clock: FixedClock(kBaseTime),
      useIsolate: false,
    );
    final preview = await backup.chooseImport();
    final controller = testController(target);
    controllers.add(controller);
    await controller.start();
    final services = testServices(repository: target, backup: backup);

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => MergePreviewScreen(preview: preview!),
          ),
        );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/p2_merge_preview_390x844.png'),
    );
  });

  testWidgets('settings at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await seededController(repository);
    final services = testServices(
      repository: repository,
      metadata: stubMetadata(),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/p2_settings_390x844.png'),
    );
  });

  testWidgets('merge preview at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));

    final source = InMemoryMediaRepository();
    await seededController(source);
    final sourceIo = FakeSnapshotIo();
    await BackupService(
      repository: source,
      io: sourceIo,
      clock: FixedClock(kBaseTime),
      useIsolate: false,
    ).export();

    final target = InMemoryMediaRepository();
    await target.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Dune (older local)',
        createdAt: '2026-09-23T10:00:00.000Z',
        updatedAt: '2026-09-23T10:00:00.000Z',
      ),
    );
    final backup = BackupService(
      repository: target,
      io: FakeSnapshotIo(
        pickResult: PickedBackup(
          fileName: 'lyberry-20260923-101500.lyberry.json',
          contents: sourceIo.savedContents!,
          byteLength: sourceIo.savedContents!.length,
        ),
      ),
      clock: FixedClock(kBaseTime),
      useIsolate: false,
    );
    final preview = await backup.chooseImport();
    final controller = testController(target);
    controllers.add(controller);
    await controller.start();

    await pumpApp(
      tester,
      controller,
      services: testServices(repository: target, backup: backup),
    );
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => MergePreviewScreen(preview: preview!),
          ),
        );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/p2_merge_preview_320x568_scale1.6.png'),
    );
  });

  testWidgets('settings at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final repository = InMemoryMediaRepository();
    final controller = await seededController(repository);
    final services = testServices(
      repository: repository,
      metadata: stubMetadata(),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/p2_settings_320x568_scale1.6.png'),
    );
  });

  /// Renders the denied-camera scan screen, whose helper under the barcode
  /// field used to be ellipsised mid-sentence on large-text devices.
  Future<void> pumpDeniedScan(WidgetTester tester) async {
    final repository = InMemoryMediaRepository();
    final controller = await seededController(repository);
    await pumpApp(
      tester,
      controller,
      services: testServices(repository: repository, metadata: stubMetadata()),
    );
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ScanScreen(
              camera: FakeScanCamera(
                previewError: const MobileScannerException(
                  errorCode: MobileScannerErrorCode.permissionDenied,
                ),
              ),
            ),
          ),
        );
    await tester.pumpAndSettle();
  }

  testWidgets('scan fallback at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await pumpDeniedScan(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/p2_scan_permission_denied_390x844.png'),
    );
  });

  testWidgets('scan fallback at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    await pumpDeniedScan(tester);
    // At this size the manual field sits below the fold, so scroll it into
    // view: the evidence has to show the whole wrapped helper, not the top.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -230));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        'goldens/p2_scan_permission_denied_320x568_scale1.6.png',
      ),
    );
  });
}
