import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/cover_downloader.dart';
import 'package:lyberry/services/image_ingest.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/services/scan_camera.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/screens/scan_screen.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../support/fake_snapshot_io.dart';
import '../support/fake_scan_camera.dart';
import '../support/fake_transport.dart';
import '../support/in_memory_repository.dart';
import '../support/stub_provider.dart';
import '../support/test_support.dart';

void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  Future<(LibraryController, InMemoryMediaRepository)> buildController({
    StubMetadataProvider? provider,
    FakeSnapshotIo? io,
  }) async {
    final repository = InMemoryMediaRepository();
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    return (controller, repository);
  }

  Future<void> pumpScanScreen(WidgetTester tester, {ScanCamera? camera}) async {
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ScanScreen(camera: camera ?? FakeScanCamera()),
      ),
    );
    await tester.pumpAndSettle();
  }

  const barcodeHelper =
      'Looking up a code needs a network connection. Adding a copy by hand '
      'always works.';

  /// Scrolls lazily built editor content into view before interacting with it.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      final scrollable = find.byType(Scrollable).first;
      await tester.drag(scrollable, const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(finder, 140, scrollable: scrollable);
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('manual code entry shows candidates and prefills the editor', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final provider = StubMetadataProvider(
      candidates: <MetadataCandidate>[
        stubCandidate(title: 'Dune', creator: 'Frank Herbert', year: 1974),
        stubCandidate(
          externalId: 'record-2',
          title: 'Dune (paperback)',
          matchKind: MatchKind.possible,
          year: null,
        ),
      ],
    );
    final (controller, repository) = await buildController();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(providers: <MetadataProvider>[provider]),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await pumpScanScreen(tester);

    await tester.enterText(
      find.byKey(const Key('scan-manual-field')),
      '9780306406157',
    );
    // The helper under the field wraps to several lines at this size, so the
    // button below it is no longer inside the first screen: scroll it in.
    await reveal(tester, find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('candidates-code')), findsOneWidget);
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Dune (paperback)'), findsOneWidget);
    expect(provider.calls, 1);

    await tester.tap(find.byKey(const Key('candidate-stub:record-1')));
    await tester.pumpAndSettle();

    // The editor is prefilled and still editable; nothing is saved yet.
    final titleField = tester.widget<TextField>(
      find.byKey(const Key('field-title')),
    );
    expect(titleField.controller?.text, 'Dune');
    expect(await repository.countItems(), 0);

    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    final stored = (await repository.listItems()).single;
    expect(stored.title, 'Dune');
    expect(stored.creator, 'Frank Herbert');
    expect(stored.year, 1974);
    expect(stored.medium, MediaType.book);
    expect(
      stored.barcode,
      '9780306406157',
      reason: 'the scanned or typed code must survive into the saved copy',
    );
    expect(stored.source?.providerId, 'stub');
    expect(stored.source?.externalId, 'record-1');
  });

  testWidgets('the scanner owns one camera lifecycle', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    final camera = FakeScanCamera();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(
        providers: <MetadataProvider>[
          StubMetadataProvider(
            candidates: <MetadataCandidate>[stubCandidate()],
          ),
        ],
      ),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(builder: (_) => ScanScreen(camera: camera)),
        );
    await tester.pumpAndSettle();
    expect(camera.isRunning, isTrue);

    // A detection stops the camera before the lookup starts.
    camera.emit('9780306406157');
    await tester.pumpAndSettle();
    expect(camera.isRunning, isFalse);
    expect(find.byKey(const Key('candidates-code')), findsOneWidget);

    // Returning to a visible scanner resumes it.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(camera.isRunning, isTrue);
  });

  testWidgets('pausing the app stops the camera and resuming restarts it', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    final camera = FakeScanCamera();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(builder: (_) => ScanScreen(camera: camera)),
        );
    await tester.pumpAndSettle();
    expect(camera.isRunning, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(camera.isRunning, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();
    expect(camera.isRunning, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(camera.isRunning, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.isRunning, isTrue);
  });

  testWidgets('rapid manual lookups start only one lookup', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final provider = StubMetadataProvider(
      candidates: <MetadataCandidate>[stubCandidate()],
    );
    final (controller, repository) = await buildController();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(providers: <MetadataProvider>[provider]),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ScanScreen(camera: FakeScanCamera()),
          ),
        );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('scan-manual-field')),
      '9780306406157',
    );
    await tester.ensureVisible(find.byKey(const Key('scan-manual-lookup')));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -80));
    await tester.pumpAndSettle();
    // Two taps without settling: the in-flight guard must absorb the second.
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();

    expect(provider.calls, 1);
    expect(find.byKey(const Key('candidates-code')), findsOneWidget);
  });

  testWidgets('no matches still allows a manual add with the code prefilled', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(
        providers: <MetadataProvider>[StubMetadataProvider()],
      ),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await pumpScanScreen(tester);

    await tester.enterText(
      find.byKey(const Key('scan-manual-field')),
      '9780306406157',
    );
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('candidates-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('candidates-empty-manual')));
    await tester.pumpAndSettle();

    final barcodeField = tester.widget<TextField>(
      find.byKey(const Key('field-barcode')),
    );
    expect(barcodeField.controller?.text, '9780306406157');
    expect(find.byKey(const Key('field-title')), findsOneWidget);
  });

  testWidgets('the barcode helper wraps fully instead of being truncated', (
    tester,
  ) async {
    // 320x568 at 1.6x text is the harshest supported layout; on the live
    // emulator the helper was ellipsised to "Addi..." before this fix.
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    final services = testServices(repository: repository);

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await pumpScanScreen(
      tester,
      camera: FakeScanCamera(
        previewError: const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied,
        ),
      ),
    );

    // The denied-camera fallback is the state the fix has to hold up in.
    expect(find.text('Camera access is off'), findsOneWidget);

    final field = tester.widget<TextField>(
      find.byKey(const Key('scan-manual-field')),
    );
    expect(field.decoration?.helperMaxLines, 4);
    expect(field.decoration?.helperText, barcodeHelper);

    final helper = tester.renderObject<RenderParagraph>(
      find.text(barcodeHelper),
    );
    expect(
      helper.didExceedMaxLines,
      isFalse,
      reason: 'the helper must not be ellipsised at 320x568 with 1.6x text',
    );
    // One line cannot hold the sentence at this size, so the rendered height
    // must be taller than a single clamped line.
    final style = (helper.text as TextSpan).style!;
    final oneLine = TextPainter(
      text: TextSpan(text: barcodeHelper, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: helper.size.width);
    expect(
      helper.size.height,
      greaterThan(oneLine.height * 1.5),
      reason: 'the sentence is too long for one line at this size, so it wraps',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the empty state points at the real scanner, not phase prose', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, _) = await buildController();

    await pumpApp(tester, controller);
    await tester.pumpAndSettle();

    expect(find.text('Scanning arrives in phase 2'), findsNothing);
    expect(find.text('Scan a barcode'), findsOneWidget);

    // The action keeps its behaviour: it opens the scanner screen, whose manual
    // fallback is present even when no camera is available in a widget test.
    await tester.tap(find.byKey(const Key('home-empty-scan')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scan-manual-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a provider outage offers retry and manual entry', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(
        providers: <MetadataProvider>[
          StubMetadataProvider(
            failure: const ProviderException(
              LookupFailureKind.network,
              'You are offline.',
            ),
          ),
        ],
      ),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await pumpScanScreen(tester);

    await tester.enterText(
      find.byKey(const Key('scan-manual-field')),
      '9780306406157',
    );
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('candidates-error')), findsOneWidget);
    expect(find.byKey(const Key('candidates-retry')), findsOneWidget);
    expect(find.byKey(const Key('candidates-error-manual')), findsOneWidget);
    expect(find.textContaining('offline'), findsWidgets);
  });

  testWidgets('settings can export and re-import a backup through the UI', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Dune',
        rating: 4.5,
      ),
    );
    await controller.refresh();

    final io = FakeSnapshotIo();
    final services = testServices(
      repository: repository,
      backup: BackupService(
        repository: repository,
        io: io,
        clock: FixedClock(kBaseTime),
        useIsolate: false,
      ),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-export')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Exported 1 copies and 0 images'),
      findsOneWidget,
    );
    expect(io.savedContents, isNotNull);

    // Import the file we just wrote; the same copy is replaced.
    io.pickResult = PickedBackup(
      fileName: 'lyberry-backup.lyberry.json',
      contents: io.savedContents!,
      byteLength: io.savedContents!.length,
    );
    await tester.tap(find.byKey(const Key('settings-import')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('merge-file-name')), findsOneWidget);
    expect(find.textContaining('Existing copies replaced'), findsOneWidget);

    await tester.tap(find.byKey(const Key('merge-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Merged: 0 new copies, 1 replaced'),
      findsOneWidget,
    );
    expect(await repository.countItems(), 1);
    expect((await repository.listItems()).single.rating, 4.5);
  });

  testWidgets('cancelling an import leaves the library untouched', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    await repository.createItem(
      sampleItem(id: '00000000-0000-4000-8000-000000000001', title: 'Kept'),
    );
    await controller.refresh();

    final io = FakeSnapshotIo();
    final services = testServices(
      repository: repository,
      backup: BackupService(
        repository: repository,
        io: io,
        clock: FixedClock(kBaseTime),
        useIsolate: false,
      ),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-import')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Import cancelled'), findsOneWidget);
    expect(await repository.countItems(), 1);
  });

  testWidgets('a malformed backup is reported without touching the library', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    await repository.createItem(
      sampleItem(id: '00000000-0000-4000-8000-000000000001', title: 'Kept'),
    );
    await controller.refresh();

    final io = FakeSnapshotIo(
      pickResult: const PickedBackup(
        fileName: 'broken.lyberry.json',
        // An unreadable future version: schema 1 and 2 are both supported now.
        contents: '{"format":"lyberry","schemaVersion":99}',
        byteLength: 38,
      ),
    );
    final services = testServices(
      repository: repository,
      backup: BackupService(
        repository: repository,
        io: io,
        clock: FixedClock(kBaseTime),
        useIsolate: false,
      ),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-import')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unsupported schema version'), findsOneWidget);
    expect(await repository.countItems(), 1);
  });

  testWidgets('candidates and merge preview fit a narrow large-text phone', (
    tester,
  ) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    final (controller, repository) = await buildController();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(
        providers: <MetadataProvider>[
          StubMetadataProvider(
            candidates: <MetadataCandidate>[
              stubCandidate(
                title: 'A very long candidate title that has to wrap somewhere',
              ),
            ],
          ),
        ],
      ),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await pumpScanScreen(tester);
    await tester.enterText(
      find.byKey(const Key('scan-manual-field')),
      '9780306406157',
    );
    // The wrapped helper pushes the button below the first screen at 320x568
    // with 1.6x text, so scroll the lazily built button into view first.
    await reveal(tester, find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-manual-lookup')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('candidates-code')), findsOneWidget);
  });

  testWidgets('back during an applying merge cannot report a cancellation', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));

    final repository = _DelayedMergeRepository();
    await repository.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'Older local copy',
      ),
    );
    final source = InMemoryMediaRepository();
    await source.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        title: 'From the file',
        barcode: '9780306406157',
      ),
    );
    await source.createItem(
      sampleItem(
        id: '00000000-0000-4000-8000-000000000002',
        title: 'Only in the file',
      ),
    );
    final sourceIo = FakeSnapshotIo();
    await BackupService(
      repository: source,
      io: sourceIo,
      clock: FixedClock(kBaseTime),
      useIsolate: false,
    ).export();

    final backup = BackupService(
      repository: repository,
      io: FakeSnapshotIo(
        pickResult: PickedBackup(
          fileName: 'lyberry-merge.lyberry.json',
          contents: sourceIo.savedContents!,
          byteLength: sourceIo.savedContents!.length,
        ),
      ),
      clock: FixedClock(kBaseTime),
      useIsolate: false,
    );
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();

    await pumpApp(
      tester,
      controller,
      services: testServices(repository: repository, backup: backup),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('merge-file-name')), findsOneWidget);

    await tester.tap(find.byKey(const Key('merge-confirm')));
    await tester.pump();
    // The transaction is still running: back must not detach this screen.
    await tester.pageBack();
    await tester.pump();
    expect(
      find.byKey(const Key('merge-file-name')),
      findsOneWidget,
      reason: 'back is blocked while the merge is applying',
    );
    // A second confirmation must not start another merge.
    await tester.tap(find.byKey(const Key('merge-confirm')));
    await tester.pump();
    expect(repository.mergeCalls, 1);

    repository.gate.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Merged:'), findsOneWidget);
    expect(find.textContaining('Import cancelled'), findsNothing);
    expect(await repository.countItems(), 2);
    expect(controller.items, hasLength(2));
  });

  testWidgets('a slow cover cannot replace a newer choice', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final slowBytes = pngBytes(
      width: 6,
      height: 6,
      red: 200,
      green: 20,
      blue: 20,
    );
    final fastBytes = pngBytes(
      width: 6,
      height: 6,
      red: 20,
      green: 20,
      blue: 200,
    );
    final transport = FakeHttpTransport();
    transport.answerBytes(
      'https://covers.openlibrary.org/b/id/1-L.jpg',
      slowBytes,
      delay: const Duration(milliseconds: 600),
    );
    transport.answerBytes(
      'https://covers.openlibrary.org/b/id/2-L.jpg',
      fastBytes,
      delay: const Duration(milliseconds: 10),
    );
    final provider = StubMetadataProvider(
      candidates: <MetadataCandidate>[
        stubCandidate(
          externalId: 'one',
          title: 'Slow cover',
          coverUrl: 'https://covers.openlibrary.org/b/id/1-L.jpg',
        ),
        stubCandidate(
          externalId: 'two',
          title: 'Fast cover',
          coverUrl: 'https://covers.openlibrary.org/b/id/2-L.jpg',
        ),
      ],
    );
    final (controller, repository) = await buildController();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(providers: <MetadataProvider>[provider]),
      covers: CoverDownloader(transport: transport),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('field-barcode')),
      '9780306406157',
    );

    // First choice: its cover takes 600 ms.
    await reveal(tester, find.byKey(const Key('field-barcode-lookup')));
    await tester.tap(find.byKey(const Key('field-barcode-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('candidate-stub:one')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    // Second choice before the first cover lands.
    await reveal(tester, find.byKey(const Key('field-barcode-lookup')));
    await tester.tap(find.byKey(const Key('field-barcode-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('candidate-stub:two')));
    await tester.pumpAndSettle();

    await reveal(tester, find.byKey(const Key('field-title')));
    await tester.enterText(find.byKey(const Key('field-title')), 'Cover race');
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    final stored = (await repository.listItems()).single;
    expect(
      stored.coverAssetId,
      const ImageIngest().buildAsset(fastBytes).id,
      reason: 'the newer choice must win over the slow download',
    );
  });

  testWidgets('a removed cover is not restored by a slow download', (
    tester,
  ) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    final fastBytes = pngBytes(
      width: 6,
      height: 6,
      red: 20,
      green: 200,
      blue: 20,
    );
    final slowBytes = pngBytes(
      width: 6,
      height: 6,
      red: 200,
      green: 200,
      blue: 20,
    );
    final transport = FakeHttpTransport();
    transport.answerBytes(
      'https://covers.openlibrary.org/b/id/1-L.jpg',
      fastBytes,
      delay: const Duration(milliseconds: 10),
    );
    transport.answerBytes(
      'https://covers.openlibrary.org/b/id/2-L.jpg',
      slowBytes,
      delay: const Duration(milliseconds: 600),
    );
    final provider = StubMetadataProvider(
      candidates: <MetadataCandidate>[
        stubCandidate(
          externalId: 'one',
          title: 'Fast cover',
          coverUrl: 'https://covers.openlibrary.org/b/id/1-L.jpg',
        ),
        stubCandidate(
          externalId: 'two',
          title: 'Slow cover',
          coverUrl: 'https://covers.openlibrary.org/b/id/2-L.jpg',
        ),
      ],
    );
    final (controller, repository) = await buildController();
    final services = testServices(
      repository: repository,
      metadata: MetadataService(providers: <MetadataProvider>[provider]),
      covers: CoverDownloader(transport: transport),
    );

    await pumpApp(tester, controller, services: services);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('field-barcode')),
      '9780306406157',
    );
    await reveal(tester, find.byKey(const Key('field-barcode-lookup')));
    await tester.tap(find.byKey(const Key('field-barcode-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('candidate-stub:one')));
    await tester.pumpAndSettle();

    // Start a slow replacement and remove the cover while it is in flight.
    await reveal(tester, find.byKey(const Key('field-barcode-lookup')));
    await tester.tap(find.byKey(const Key('field-barcode-lookup')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('candidate-stub:two')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await reveal(tester, find.byKey(const Key('cover-remove')));
    await tester.tap(find.byKey(const Key('cover-remove')));
    await tester.pumpAndSettle();

    await reveal(tester, find.byKey(const Key('field-title')));
    await tester.enterText(find.byKey(const Key('field-title')), 'No cover');
    await tester.tap(find.byKey(const Key('editor-save')));
    await tester.pumpAndSettle();

    final stored = (await repository.listItems()).single;
    expect(
      stored.coverAssetId,
      isNull,
      reason: 'a removed cover must stay removed',
    );
  });
}

/// In-memory store whose merge waits for the test to release it.
class _DelayedMergeRepository extends InMemoryMediaRepository {
  final Completer<void> gate = Completer<void>();
  int mergeCalls = 0;

  @override
  Future<MergeResult> mergeSnapshot(LibrarySnapshot snapshot) async {
    mergeCalls++;
    await gate.future;
    return super.mergeSnapshot(snapshot);
  }
}
