/// Small, strict-ish helpers shared by the provider adapters.
String jsonString(Object? value) => value is String ? value : '';

/// Integer reader for ids and counts. Numeric strings are accepted; anything
/// else (including fractions) is `null` so a malformed id never becomes a
/// plausible-looking number.
int? jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) {
    if (value.isNaN || value.isInfinite) return null;
    if (value != value.roundToDouble()) return null;
    return value.round();
  }
  final text = jsonString(value).trim();
  if (text.isEmpty) return null;
  return int.tryParse(text);
}

Map<String, Object?>? jsonMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

List<Object?> jsonList(Object? value) =>
    value is List ? value : const <Object?>[];

/// Reads a year from a free-form date such as `1965`, `March 1965` or
/// `1965-08-01`. Never guesses: no four-digit year means no year.
int? jsonYear(Object? value) {
  if (value is int) return _sane(value);
  final text = jsonString(value);
  if (text.isEmpty) return null;
  final match = RegExp(r'(\d{4})').firstMatch(text);
  if (match == null) return null;
  return _sane(int.tryParse(match.group(1)!));
}

int? _sane(int? year) {
  if (year == null || year < 1 || year > 9999) return null;
  return year;
}

/// First non-empty string of a list-ish JSON value.
String jsonFirstString(Object? value) {
  for (final entry in jsonList(value)) {
    final text = jsonString(entry);
    if (text.trim().isNotEmpty) return text;
  }
  return '';
}
