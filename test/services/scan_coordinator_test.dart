import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/services/scan_coordinator.dart';

import '../support/test_support.dart';

void main() {
  group('scan coordinator', () {
    test('debounces repeated frames of the same barcode', () async {
      final handled = <String>[];
      final events = <String>[];
      final clock = FixedClock(kBaseTime);
      final coordinator = ScanCoordinator(
        onIdentifier: (identifier) async {
          handled.add(identifier.value);
        },
        pauseCamera: () async => events.add('pause'),
        resumeCamera: () async => events.add('resume'),
        clock: clock,
        debounce: const Duration(milliseconds: 1500),
      );

      expect(await coordinator.onDetected('9780306406157'), isTrue);
      expect(await coordinator.onDetected('9780306406157'), isFalse);
      expect(await coordinator.onDetected('978-0-306-40615-7'), isFalse);
      expect(handled, <String>['9780306406157']);

      clock.advance(const Duration(seconds: 2));
      expect(await coordinator.onDetected('9780306406157'), isTrue);
      expect(handled, hasLength(2));

      await coordinator.resume();
      expect(events, <String>['pause', 'pause', 'resume']);
    });

    test('stops the camera before the lookup runs', () async {
      final order = <String>[];
      final coordinator = ScanCoordinator(
        onIdentifier: (identifier) async => order.add('lookup'),
        pauseCamera: () async => order.add('pause'),
        resumeCamera: () async => order.add('resume'),
        clock: FixedClock(kBaseTime),
      );

      await coordinator.onDetected('9780306406157');

      expect(order, <String>['pause', 'lookup']);
    });

    test('ignores codes that are not valid identifiers', () async {
      var calls = 0;
      final coordinator = ScanCoordinator(
        onIdentifier: (identifier) async => calls++,
        pauseCamera: () async {},
        resumeCamera: () async {},
        clock: FixedClock(kBaseTime),
      );

      expect(await coordinator.onDetected('hello'), isFalse);
      expect(await coordinator.onDetected('9780306406158'), isFalse);
      expect(calls, 0);
    });

    test('different codes are handled separately', () async {
      final handled = <IdentifierKind>[];
      final coordinator = ScanCoordinator(
        onIdentifier: (identifier) async => handled.add(identifier.kind),
        pauseCamera: () async {},
        resumeCamera: () async {},
        clock: FixedClock(kBaseTime),
      );

      await coordinator.onDetected('9780306406157');
      await coordinator.onDetected('0724384654726');

      expect(handled, <IdentifierKind>[
        IdentifierKind.isbn13,
        IdentifierKind.ean13,
      ]);
    });

    test('a failing lookup does not wedge the coordinator', () async {
      var attempts = 0;
      final coordinator = ScanCoordinator(
        onIdentifier: (identifier) async {
          attempts++;
          throw StateError('lookup blew up');
        },
        pauseCamera: () async {},
        resumeCamera: () async {},
        clock: FixedClock(kBaseTime),
      );

      await expectLater(
        coordinator.onDetected('9780306406157'),
        throwsA(isA<StateError>()),
      );
      expect(coordinator.isHandling, isFalse);
      await expectLater(
        coordinator.onDetected('0724384654726'),
        throwsA(isA<StateError>()),
      );
      expect(attempts, 2);
    });
  });
}
