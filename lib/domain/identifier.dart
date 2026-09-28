import 'package:lyberry/domain/barcode.dart';
import 'package:lyberry/domain/validation.dart';

/// The identifier families Lyberry can look up.
enum IdentifierKind {
  isbn10('ISBN-10'),
  isbn13('ISBN-13'),
  ean13('EAN-13'),
  ean8('EAN-8'),
  upcA('UPC-A');

  const IdentifierKind(this.label);

  final String label;
}

/// A scanned or typed code, normalized once, with every equivalent form.
///
/// Providers get the form they understand; the library stores the canonical
/// [value], so an ISBN-10 and the same book's ISBN-13 never look like two
/// different codes.
class NormalizedIdentifier {
  const NormalizedIdentifier({
    required this.raw,
    required this.value,
    required this.kind,
    required this.equivalents,
  });

  final String raw;
  final String value;
  final IdentifierKind kind;

  /// Every equivalent code, including [value].
  final Set<String> equivalents;

  bool get isIsbn =>
      kind == IdentifierKind.isbn10 || kind == IdentifierKind.isbn13;

  /// One value per logical code, so equivalent forms share routing and cache
  /// entries: an ISBN-10 and its ISBN-13, or a UPC-A and its EAN-13 form.
  String get canonicalKey {
    if (isIsbn) return canonicalIsbn13;
    if (kind == IdentifierKind.upcA) return '0$value';
    return value;
  }

  /// True when [code] is one of this identifier's stored forms.
  bool matches(String code) {
    final normalized = code.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    return equivalents.contains(normalized);
  }

  /// ISBN-13 form when this code is (or maps to) an ISBN.
  String get canonicalIsbn13 {
    if (kind == IdentifierKind.isbn13) return value;
    if (kind == IdentifierKind.isbn10) return Barcode.isbn13FromIsbn10(value);
    return value;
  }

  @override
  String toString() => 'NormalizedIdentifier($value, ${kind.name})';
}

abstract final class IdentifierNormalizer {
  /// Strips separators, validates the checksum and returns `null` when the
  /// input is not a usable code.
  static NormalizedIdentifier? tryNormalize(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    if (cleaned.isEmpty || !Barcode.isValid(cleaned)) return null;

    final IdentifierKind kind;
    switch (cleaned.length) {
      case 8:
        kind = IdentifierKind.ean8;
      case 10:
        kind = IdentifierKind.isbn10;
      case 12:
        kind = IdentifierKind.upcA;
      case 13:
        kind = cleaned.startsWith('978') || cleaned.startsWith('979')
            ? IdentifierKind.isbn13
            : IdentifierKind.ean13;
      default:
        return null;
    }
    return NormalizedIdentifier(
      raw: raw,
      value: cleaned,
      kind: kind,
      equivalents: _equivalents(cleaned, kind),
    );
  }

  static NormalizedIdentifier normalize(String raw) {
    final identifier = tryNormalize(raw);
    if (identifier == null) {
      throw const ValidationException([
        ValidationIssue(
          'barcode',
          'Use a valid ISBN-10, ISBN-13, EAN-13, EAN-8 or UPC-A code.',
        ),
      ]);
    }
    return identifier;
  }

  static Set<String> _equivalents(String value, IdentifierKind kind) {
    final forms = <String>{value};
    switch (kind) {
      case IdentifierKind.isbn10:
        forms.add(Barcode.isbn13FromIsbn10(value));
      case IdentifierKind.isbn13:
        final isbn10 = Barcode.isbn10FromIsbn13(value);
        if (isbn10 != null) forms.add(isbn10);
      case IdentifierKind.upcA:
        forms.add('0$value');
      case IdentifierKind.ean13:
        if (value.startsWith('0')) forms.add(value.substring(1));
      case IdentifierKind.ean8:
        break;
    }
    return Set<String>.unmodifiable(forms);
  }
}
