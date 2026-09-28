/// Identifier matching that tolerates the separators retailers print.
///
/// A code is only ever "present" as a whole identifier: `5051888100639` counts,
/// `15051888100639` does not, and the same rule applies when the page prints
/// `505 1888 100639`, `505-1888-100639` or a mixed form.
abstract final class CodeMatching {
  static const int defaultMaxHits = 4;

  /// True when any equivalent form appears as a whole identifier in [text].
  static bool containsCode(
    String text,
    Iterable<String> equivalents, {
    int maxHits = defaultMaxHits,
  }) => occurrences(text, equivalents, maxHits: maxHits).isNotEmpty;

  /// True when [quote] itself carries the code as a whole identifier.
  static bool quoteCarriesCode(String quote, Iterable<String> equivalents) =>
      containsCode(quote, equivalents, maxHits: 1);

  /// Start indices in [text] where an equivalent form appears.
  ///
  /// Separators (`space`, `-`, `_`, `.`, `/`) may appear between digits of the
  /// code, but the match must not sit inside a longer digit run.
  static List<int> occurrences(
    String text,
    Iterable<String> equivalents, {
    int maxHits = defaultMaxHits,
  }) {
    final upper = text.toUpperCase();
    final found = <int>[];
    for (final code in equivalents) {
      final needle = code.replaceAll(RegExp(r'[\s\-_.\/]'), '').toUpperCase();
      if (needle.isEmpty) continue;
      var start = 0;
      while (start < upper.length) {
        if (!_isDigit(upper.codeUnitAt(start))) {
          start++;
          continue;
        }
        final end = _matchAt(upper, start, needle);
        if (end == null) {
          start++;
          continue;
        }
        if (_isWholeIdentifier(upper, start, end)) {
          found.add(start);
          if (found.length >= maxHits) return found;
        }
        start = end;
      }
    }
    found.sort();
    return found.length > maxHits ? found.sublist(0, maxHits) : found;
  }

  /// Index just past the match that starts at [start], or null when the code
  /// does not match there.
  static int? _matchAt(String text, int start, String needle) {
    var index = start;
    var matched = 0;
    while (matched < needle.length) {
      if (index >= text.length) return null;
      final unit = text.codeUnitAt(index);
      final char = String.fromCharCode(unit);
      if (_isSeparator(char)) {
        index++;
        continue;
      }
      if (char != needle[matched]) return null;
      matched++;
      index++;
    }
    return index;
  }

  /// True when the match is not glued to another digit or code character.
  static bool _isWholeIdentifier(String text, int start, int end) {
    var before = start - 1;
    while (before >= 0 &&
        _isSeparator(String.fromCharCode(text.codeUnitAt(before)))) {
      before--;
    }
    if (before >= 0 && _isDigit(text.codeUnitAt(before))) return false;
    var after = end;
    while (after < text.length &&
        _isSeparator(String.fromCharCode(text.codeUnitAt(after)))) {
      after++;
    }
    if (after < text.length && _isDigit(text.codeUnitAt(after))) return false;
    return true;
  }

  /// Only digits glue two identifiers together; a neighbouring letter (as in
  /// `Barcode 5051888100639` or `ISBN 5051888100639`) is a word boundary.
  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  static bool _isSeparator(String char) =>
      char == ' ' ||
      char == '\t' ||
      char == '\n' ||
      char == '\r' ||
      char == '-' ||
      char == '_' ||
      char == '.' ||
      char == '/';
}
