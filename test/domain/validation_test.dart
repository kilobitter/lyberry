import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/barcode.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/state/item_draft.dart';

import '../support/test_support.dart';

void main() {
  group('rating rules', () {
    test('accepts null and half-star values in range', () {
      expect(RatingRules.isValid(null), isTrue);
      for (final value in <double>[0.5, 1.0, 3.5, 5.0]) {
        expect(RatingRules.isValid(value), isTrue, reason: '$value');
      }
    });

    test('rejects values off the half-star grid or out of range', () {
      for (final value in <double>[
        0.25,
        0.3,
        5.5,
        -1,
        double.nan,
        double.infinity,
      ]) {
        expect(RatingRules.isValid(value), isFalse, reason: '$value');
      }
    });

    test('snaps arbitrary input onto the grid', () {
      expect(RatingRules.snap(0.1), 0.5);
      expect(RatingRules.snap(3.26), 3.5);
      expect(RatingRules.snap(9), 5.0);
      expect(RatingRules.snap(null), isNull);
    });
  });

  group('barcode', () {
    test('round-trips the supported identifier families', () {
      for (final code in <String>[
        '9780306406157',
        '0306406152',
        '96385074',
        '036000291452',
        '9780441013593',
      ]) {
        expect(Barcode.isValid(code), isTrue, reason: code);
        expect(Barcode.normalize(code), code);
      }
    });

    test('normalizes separators and isbn-10 X check digit', () {
      expect(Barcode.normalize('978-0-306-40615-7'), '9780306406157');
      expect(Barcode.normalize('0 975 22980 x'), '097522980X');
      expect(Barcode.isValid('097522980X'), isTrue);
      // 0306406152 is valid, but the same body with an X check digit is not.
      expect(Barcode.isValid('030640615X'), isFalse);
    });

    test('rejects wrong checksums, length and alphabet', () {
      expect(Barcode.isValid('9780306406158'), isFalse);
      expect(Barcode.isValid('96385075'), isFalse);
      expect(Barcode.isValid('12345'), isFalse);
      expect(Barcode.isValid('97803064061AB'), isFalse);
      expect(Barcode.normalize('not a code'), isNull);
      expect(Barcode.describeProblem('9780306406158'), isNotNull);
      expect(Barcode.describeProblem(''), isNull);
    });
  });

  group('item validation', () {
    test('accepts a complete item', () {
      final item = sampleItem(
        id: '00000000-0000-4000-8000-000000000001',
        barcode: '9780306406157',
        rating: 4.5,
        coverAssetId: 'a' * 64,
        photoAssetIds: <String>['b' * 64],
      );
      expect(ItemValidator.validate(item), isEmpty);
    });

    test('reports identity, title and year problems', () {
      final issues = ItemValidator.validate(
        sampleItem(id: 'not-a-uuid', title: '   ', year: 12000),
      );
      final fields = issues.map((issue) => issue.field).toSet();
      expect(fields, containsAll(<String>['id', 'title', 'year']));
    });

    test('enforces string bounds per field', () {
      final issues = ItemValidator.validate(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000002',
          creator: 'c' * (FieldLimits.shortText + 1),
          notes: 'n' * (FieldLimits.longText + 1),
        ),
      );
      final fields = issues.map((issue) => issue.field).toSet();
      expect(fields, containsAll(<String>['creator', 'notes']));
    });

    test('rejects an invalid barcode and bad photo references', () {
      final issues = ItemValidator.validate(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000003',
          barcode: '9780306406158',
          photoAssetIds: <String>['not-a-hash'],
        ),
      );
      final fields = issues.map((issue) => issue.field).toSet();
      expect(fields, containsAll(<String>['barcode', 'photoAssetIds']));
    });

    test('caps personal photos and requires unique references', () {
      final tooMany = ItemValidator.validate(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000004',
          photoAssetIds: <String>[
            for (var index = 0; index < FieldLimits.maxPhotos + 1; index++)
              index.toString().padLeft(64, '0'),
          ],
        ),
      );
      expect(tooMany.map((issue) => issue.field), contains('photoAssetIds'));

      final duplicated = ItemValidator.validate(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000005',
          photoAssetIds: <String>['a' * 64, 'a' * 64],
        ),
      );
      expect(duplicated.map((issue) => issue.field), contains('photoAssetIds'));
    });

    test('rejects non-UTC timestamps', () {
      final issues = ItemValidator.validate(
        sampleItem(
          id: '00000000-0000-4000-8000-000000000006',
          createdAt: '2026-09-23T10:00:00+02:00',
        ),
      );
      expect(issues.map((issue) => issue.field), contains('createdAt'));
    });
  });

  group('editor draft', () {
    test('trims text and normalizes the barcode', () {
      final item =
          ItemDraft(
            medium: MediaType.book,
            title: '  Dune  ',
            creator: ' Frank Herbert ',
            yearText: '1965',
            barcode: '978-0-306-40615-7',
            rating: 4.5,
          ).buildItem(
            id: '00000000-0000-4000-8000-00000000000a',
            createdAt: kBaseTimestamp,
            updatedAt: kBaseTimestamp,
          );
      expect(item.title, 'Dune');
      expect(item.creator, 'Frank Herbert');
      expect(item.barcode, '9780306406157');
      expect(item.year, 1965);
    });

    test('collects title, year and barcode problems together', () {
      expect(
        () =>
            ItemDraft(
              medium: MediaType.cd,
              title: ' ',
              yearText: '19x5',
              barcode: '123',
            ).buildItem(
              id: '00000000-0000-4000-8000-00000000000b',
              createdAt: kBaseTimestamp,
              updatedAt: kBaseTimestamp,
            ),
        throwsA(
          isA<ValidationException>().having(
            (error) => error.issues.map((issue) => issue.field).toSet(),
            'fields',
            containsAll(<String>['title', 'year', 'barcode']),
          ),
        ),
      );
    });
  });
}
