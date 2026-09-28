import 'dart:async';

import 'package:lyberry/services/rate_limiter.dart';

/// Shared admission control for UPCMDB requests.
///
/// Spacing and concurrency are enforced around every request - barcode
/// identification and title search share one gate - so the free tier's
/// conservative one-request-per-second budget is respected even when a scan and
/// a search happen close together. A server 429 cooldown taken on one path
/// blocks the other as well.
class MoviesRequestGate {
  MoviesRequestGate({required this.limiter, this.maxConcurrent = 2})
    : assert(maxConcurrent > 0 && maxConcurrent < 8);

  final ProviderRateLimiter limiter;
  final int maxConcurrent;

  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  int get active => _active;
  Duration get cooldownRemaining => limiter.cooldownRemaining;

  /// Runs [action] once a slot is free and the spacing rule is satisfied.
  ///
  /// The limiter's own guard throws a typed cooldown failure when a server
  /// cooldown is longer than one request interval; nothing here retries
  /// silently.
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
