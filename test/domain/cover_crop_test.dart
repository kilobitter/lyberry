import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/validation.dart';

void main() {
  group('CoverCrop validation', () {
    test('the full frame is valid and flagged as full', () {
      expect(CoverCrop.full.validate(), isEmpty);
      expect(CoverCrop.full.isFull, isTrue);
      expect(const CoverCrop(left: 0.1, width: 0.8).isFull, isFalse);
      expect(const CoverCrop(quarterTurns: 1).isFull, isFalse);
    });

    test('every quarter turn is accepted and nothing else is', () {
      for (final turns in <int>[0, 1, 2, 3]) {
        expect(
          CoverCrop(quarterTurns: turns).validate(),
          isEmpty,
          reason: 'turns=$turns',
        );
      }
      for (final turns in <int>[-1, 4, 7]) {
        expect(
          CoverCrop(quarterTurns: turns).validate(),
          isNotEmpty,
          reason: 'turns=$turns',
        );
      }
    });

    test('empty and negative rectangles are rejected', () {
      expect(const CoverCrop(width: 0).validate(), isNotEmpty);
      expect(const CoverCrop(height: 0).validate(), isNotEmpty);
      expect(const CoverCrop(width: -0.5).validate(), isNotEmpty);
      expect(const CoverCrop(height: -0.5).validate(), isNotEmpty);
    });

    test('rectangles outside the photo are rejected', () {
      expect(const CoverCrop(left: 0.9, width: 0.2).validate(), isNotEmpty);
      expect(const CoverCrop(top: 0.9, height: 0.2).validate(), isNotEmpty);
      expect(const CoverCrop(left: -0.1).validate(), isNotEmpty);
      expect(const CoverCrop(top: -0.1).validate(), isNotEmpty);
    });

    test('non-finite values are rejected', () {
      expect(
        const CoverCrop(width: double.nan, height: 1).validate(),
        isNotEmpty,
      );
      expect(const CoverCrop(left: double.infinity).validate(), isNotEmpty);
      expect(
        const CoverCrop(height: double.negativeInfinity).validate(),
        isNotEmpty,
      );
    });

    test('a hair outside the edge is still accepted', () {
      // Floating point drag arithmetic can land a few ulps past 1.0.
      expect(const CoverCrop(left: 0.5, width: 0.5 + 1e-9).validate(), isEmpty);
    });

    test('assertValid throws the same issues it reports', () {
      expect(
        () => const CoverCrop(width: 0).assertValid(),
        throwsA(isA<ValidationException>()),
      );
      expect(() => CoverCrop.full.assertValid(), returnsNormally);
    });
  });

  group('CoverCrop pixel mapping', () {
    test('maps normalized coordinates onto whole pixels', () {
      final pixels = const CoverCrop(
        left: 0.25,
        top: 0.5,
        width: 0.5,
        height: 0.25,
      ).toPixels(imageWidth: 400, imageHeight: 200);
      expect(pixels.x, 100);
      expect(pixels.y, 100);
      expect(pixels.width, 200);
      expect(pixels.height, 50);
    });

    test('clamps a sliver at the edge to at least one pixel', () {
      final pixels = const CoverCrop(
        left: 0.999,
        top: 0.999,
        width: 0.001,
        height: 0.001,
      ).toPixels(imageWidth: 100, imageHeight: 100);
      expect(pixels.x, 100 - 1);
      expect(pixels.y, 100 - 1);
      expect(pixels.width, greaterThanOrEqualTo(1));
      expect(pixels.height, greaterThanOrEqualTo(1));
      expect(pixels.x + pixels.width, lessThanOrEqualTo(100));
      expect(pixels.y + pixels.height, lessThanOrEqualTo(100));
    });
  });

  group('CoverCrop value semantics', () {
    test('copyWith replaces only the named fields', () {
      const base = CoverCrop(left: 0.1, top: 0.2, width: 0.3, height: 0.4);
      final updated = base.copyWith(quarterTurns: 2);
      expect(updated.left, 0.1);
      expect(updated.top, 0.2);
      expect(updated.width, 0.3);
      expect(updated.height, 0.4);
      expect(updated.quarterTurns, 2);
    });

    test('equality and hashCode follow the values', () {
      const a = CoverCrop(left: 0.1, top: 0.2, width: 0.3, height: 0.4);
      const b = CoverCrop(left: 0.1, top: 0.2, width: 0.3, height: 0.4);
      const c = CoverCrop(left: 0.1, top: 0.2, width: 0.3, height: 0.5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
