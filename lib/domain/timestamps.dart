/// Canonical UTC ISO-8601 encoding used for every stored timestamp.
///
/// The stored strings always carry milliseconds and a trailing `Z`, so plain
/// lexicographic ordering matches chronological ordering.
String encodeTimestamp(DateTime value) => value.toUtc().toIso8601String();

/// Parses a stored timestamp, returning `null` for anything that is not a
/// UTC ISO-8601 instant.
DateTime? tryDecodeTimestamp(Object? value) {
  if (value is! String || !value.endsWith('Z')) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return parsed.toUtc();
}

DateTime decodeTimestamp(Object? value) {
  final parsed = tryDecodeTimestamp(value);
  if (parsed == null) {
    throw FormatException('Not a UTC ISO-8601 timestamp: $value');
  }
  return parsed;
}

/// True only for the exact canonical form Lyberry writes, so imported files
/// cannot smuggle in a different instant through a loose parse.
bool isCanonicalTimestamp(Object? value) {
  final parsed = tryDecodeTimestamp(value);
  return parsed != null && encodeTimestamp(parsed) == value;
}
