/// Tiny ordered list comparison used by the immutable domain models.
///
/// Kept local so the domain layer does not depend on Flutter or extra packages.
bool orderedListEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

int orderedListHash<T>(List<T> values) => Object.hashAll(values);
