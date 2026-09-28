/// Normalization and checksum validation for the identifier families Lyberry
/// stores: ISBN-10, ISBN-13, EAN-13, EAN-8 and UPC-A.
abstract final class Barcode {
  static final RegExp _digitsOnly = RegExp(r'^[0-9]+$');

  /// Removes separators and validates the checksum. Returns `null` when the
  /// value is not a valid code.
  static String? normalize(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    if (cleaned.isEmpty) return null;
    return isValid(cleaned) ? cleaned : null;
  }

  static bool isValid(String code) {
    if (code.length == 10) return _isValidIsbn10(code);
    if (!_digitsOnly.hasMatch(code)) return false;
    return switch (code.length) {
      8 || 12 || 13 => _hasValidMod10CheckDigit(code),
      _ => false,
    };
  }

  /// Appends the EAN/UPC mod-10 check digit to a 7, 11 or 12 digit body.
  static String withMod10CheckDigit(String body) =>
      '$body${_mod10CheckDigit(body)}';

  static int _mod10CheckDigit(String body) {
    var sum = 0;
    for (var index = body.length - 1; index >= 0; index--) {
      final digit = body.codeUnitAt(index) - 0x30;
      final fromRight = body.length - 1 - index;
      sum += digit * (fromRight.isEven ? 3 : 1);
    }
    return (10 - (sum % 10)) % 10;
  }

  /// Converts a valid ISBN-10 into the equivalent ISBN-13 (978 prefix).
  static String isbn13FromIsbn10(String isbn10) {
    if (!_isValidIsbn10(isbn10)) {
      throw FormatException('Not a valid ISBN-10: $isbn10');
    }
    return withMod10CheckDigit('978${isbn10.substring(0, 9)}');
  }

  /// Converts a 978-prefixed ISBN-13 into its ISBN-10 form, or `null` when the
  /// code has no ISBN-10 equivalent (979 range or not an ISBN-13).
  static String? isbn10FromIsbn13(String isbn13) {
    if (isbn13.length != 13 || !isbn13.startsWith('978') || !isValid(isbn13)) {
      return null;
    }
    final body = isbn13.substring(3, 12);
    var sum = 0;
    for (var index = 0; index < 9; index++) {
      sum += (body.codeUnitAt(index) - 0x30) * (10 - index);
    }
    final check = (11 - (sum % 11)) % 11;
    return '$body${check == 10 ? 'X' : check}';
  }

  /// EAN-8, UPC-A, EAN-13 (ISBN-13 shares the EAN-13 check digit rule).
  static bool _hasValidMod10CheckDigit(String code) {
    var sum = 0;
    for (var index = code.length - 2; index >= 0; index--) {
      final digit = code.codeUnitAt(index) - 0x30;
      final weight = (code.length - 1 - index).isOdd ? 3 : 1;
      sum += digit * weight;
    }
    final expected = (10 - (sum % 10)) % 10;
    return expected == code.codeUnitAt(code.length - 1) - 0x30;
  }

  static bool _isValidIsbn10(String code) {
    var sum = 0;
    for (var index = 0; index < 9; index++) {
      final digit = code.codeUnitAt(index) - 0x30;
      if (digit < 0 || digit > 9) return false;
      sum += digit * (10 - index);
    }
    final last = code[9];
    final int lastValue;
    if (last == 'X') {
      lastValue = 10;
    } else {
      lastValue = last.codeUnitAt(0) - 0x30;
      if (lastValue < 0 || lastValue > 9) return false;
    }
    return (sum + lastValue) % 11 == 0;
  }

  static final RegExp _isbn10Shape = RegExp(r'^[0-9]{9}[0-9X]$');

  /// Validates a user-entered code, returning a message when it cannot be used.
  static String? describeProblem(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final cleaned = trimmed.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    if (!_digitsOnly.hasMatch(cleaned) && !_isbn10Shape.hasMatch(cleaned)) {
      return 'Use digits only (an ISBN-10 may end in X).';
    }
    if (isValid(cleaned)) return null;
    return 'That barcode or ISBN checksum does not look right.';
  }
}
