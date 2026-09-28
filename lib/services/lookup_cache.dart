import 'dart:collection';

import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';

/// Small LRU cache for completed lookups, so repeated scans do not spend free
/// provider quota again.
class LookupCache {
  LookupCache({
    this.maxEntries = 64,
    this.ttl = const Duration(hours: 12),
    Clock? clock,
  }) : _clock = clock ?? const SystemClock();

  final int maxEntries;
  final Duration ttl;
  final Clock _clock;
  final LinkedHashMap<String, _Entry> _entries =
      LinkedHashMap<String, _Entry>();

  int get length => _entries.length;

  List<MetadataCandidate>? get(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_clock.nowUtc().difference(entry.storedAt) > ttl) return null;
    _entries[key] = entry; // touch for LRU ordering
    return entry.candidates;
  }

  void put(String key, List<MetadataCandidate> candidates) {
    _entries.remove(key);
    _entries[key] = _Entry(
      candidates: List<MetadataCandidate>.unmodifiable(candidates),
      storedAt: _clock.nowUtc(),
    );
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}

class _Entry {
  const _Entry({required this.candidates, required this.storedAt});

  final List<MetadataCandidate> candidates;
  final DateTime storedAt;
}
