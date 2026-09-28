import 'dart:async';

import 'package:lyberry/services/rate_limiter.dart';

/// Shared admission control for IGDB requests.
///
/// Spacing and concurrency are enforced at the HTTP boundary - around every
/// POST, including the single 401 retry - so a slow shared token exchange can
/// never bunch several later requests together. Server 429 cooldowns are
/// applied to the same object, so a cooldown taken on the barcode path also
/// blocks the title path.
class GamesRequestGate {
  GamesRequestGate({required this.limiter, this.maxConcurrent = 6})
    : assert(maxConcurrent > 0 && maxConcurrent < 8);

  final ProviderRateLimiter limiter;
  final int maxConcurrent;

  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  int get active => _active;
  Duration get cooldownRemaining => limiter.cooldownRemaining;

  /// Runs [action] once a slot is free and the spacing rule is satisfied.
  Future<T> run<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      await limiter.guard();
      return await action();
    } finally {
      _release();
    }
  }

  /// Applies a server-provided cooldown (for example a 429 `Retry-After`).
  void penalize(Duration duration) => limiter.penalize(duration);

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    // Hand the slot straight to the next waiter so the cap is exact.
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
  }
}
