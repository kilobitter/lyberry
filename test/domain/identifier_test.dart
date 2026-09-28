import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/domain/barcode.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/validation.dart';

void main() {
  group('identifier normalization', () {
    test('normalizes a hyphenated ISBN-10 and pairs it with its ISBN-13', () {
      final identifier = IdentifierNormalizer.normalize('0-306-40615-2');

      expect(identifier.kind, IdentifierKind.isbn10);
      expect(identifier.value, '0306406152');
      expect(identifier.isIsbn, isTrue);
      expect(identifier.canonicalIsbn13, '9780306406157');
      expect(
        identifier.equivalents,
        containsAll(<String>['0306406152', '9780306406157']),
      );
    });

    test('pairs an ISBN-13 with its ISBN-10 form', () {
      final identifier = IdentifierNormalizer.normalize('978-0-306-40615-7');

      expect(identifier.kind, IdentifierKind.isbn13);
      expect(identifier.equivalents, contains('0306406152'));
    });

    test('treats UPC-A and its zero-prefixed EAN-13 as the same code', () {
      final upc = IdentifierNormalizer.normalize('036000291452');
      final ean = IdentifierNormalizer.normalize('0036000291452');

      expect(upc.kind, IdentifierKind.upcA);
      expect(ean.kind, IdentifierKind.ean13);
      expect(upc.equivalents, contains('0036000291452'));
      expect(ean.equivalents, contains('036000291452'));
    });

    test('keeps EAN-8 and non-ISBN EAN-13 standalone', () {
      final ean8 = IdentifierNormalizer.normalize('96385074');
      final ean13 = IdentifierNormalizer.normalize('1234567890128');

      expect(ean8.kind, IdentifierKind.ean8);
      expect(ean8.equivalents, <String>{'96385074'});
      expect(ean13.kind, IdentifierKind.ean13);
      expect(ean13.isIsbn, isFalse);
    });

    test('979 ISBN-13 codes have no ISBN-10 equivalent', () {
      expect(Barcode.isbn10FromIsbn13('9791234567896'), isNull);
    });

    test('rejects bad checksums, junk and empty input', () {
      expect(IdentifierNormalizer.tryNormalize('9780306406158'), isNull);
      expect(IdentifierNormalizer.tryNormalize('not a code'), isNull);
      expect(IdentifierNormalizer.tryNormalize(''), isNull);
      expect(
        () => IdentifierNormalizer.normalize('12345'),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('barcode conversion helpers', () {
    test('round-trips ISBN-10 and ISBN-13', () {
      expect(Barcode.isbn13FromIsbn10('0306406152'), '9780306406157');
      expect(Barcode.isbn10FromIsbn13('9780306406157'), '0306406152');
      expect(Barcode.isbn13FromIsbn10('097522980X'), '9780975229804');
    });

    test('appends mod-10 check digits', () {
      expect(Barcode.withMod10CheckDigit('03600029145'), '036000291452');
      expect(Barcode.withMod10CheckDigit('978030640615'), '9780306406157');
    });
  });
}
