import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/state/library_controller.dart';

import '../support/in_memory_repository.dart';
import '../support/test_support.dart';

// Renders the home Games platform filter (closed and open menu).
// Run with: flutter test --update-goldens test/golden/platform_filter_render_test.dart
// The PNGs are copied into docs/agent-work/lyberry/evidence/platform-filter/.
void main() {
  setUpAll(loadAppFonts);

  late List<LibraryController> controllers;

  setUp(() => controllers = <LibraryController>[]);

  tearDown(() {
    for (final controller in controllers) {
      controller.dispose();
    }
  });

  Future<LibraryController> seeded(WidgetTester tester) async {
    final repository = InMemoryMediaRepository();
    final seeds = <(String, String, String, String)>[
      (
        '00000000-0000-4000-8000-000000000001',
        'Station Game',
        'PlayStation 4',
        '2026-09-23T13:00:00.000Z',
      ),
      (
        '00000000-0000-4000-8000-000000000002',
        'Retro Game',
        'Super Nintendo',
        '2026-09-23T12:00:00.000Z',
      ),
      (
        '00000000-0000-4000-8000-000000000003',
        'Long Platform Game',
        'Super Nintendo Entertainment System - Super Famicom (PAL)',
        '2026-09-23T11:00:00.000Z',
      ),
    ];
    for (final seed in seeds) {
      await repository.createItem(
        sampleItem(
          id: seed.$1,
          medium: MediaType.game,
          title: seed.$2,
          platform: seed.$3,
          createdAt: seed.$4,
          updatedAt: seed.$4,
        ),
      );
    }
    final controller = testController(repository);
    controllers.add(controller);
    await controller.start();
    await pumpApp(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Games'));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('platform filter closed at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await seeded(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/platform_filter_closed_390x844.png'),
    );
  });

  testWidgets('platform filter open at 390x844', (tester) async {
    useSurface(tester);
    addTearDown(() => resetSurface(tester));
    await seeded(tester);

    await tester.tap(find.byKey(const Key('home-platform')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/platform_filter_open_390x844.png'),
    );
  });

  testWidgets('platform filter open at 320x568 with 1.6x text', (tester) async {
    useSurface(tester, size: const Size(320, 568), textScale: 1.6);
    addTearDown(() => resetSurface(tester));
    await seeded(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('home-platform')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-platform')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/platform_filter_open_320x568_scale1.6.png'),
    );
  });
}
