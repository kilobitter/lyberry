import 'dart:async';

import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';

/// Per-provider request spacing plus server cooldowns.
///
/// The limiter never hides a long wait behind a spinner: [acquire] waits only
/// for short spacing, and returns the remaining time instead of sleeping when
/// the wait is longer than [maxWait] (a quota cooldown, or UPCitemdb's 10 s
/// spacing). Providers turn that returned wait into a typed quota failure, so
/// the UI can show "cooling down" and manual entry stays available.
class ProviderRateLimiter {
  ProviderRateLimiter({
    required this.providerId,
    required this.minInterval,
    this.clock = const SystemClock(),
  });

  final String providerId;
  final Duration minInterval;
  final Clock clock;

  DateTime? _lastRequestAt;
  DateTime? _cooldownUntil;

  /// Cooldown from a server response, if any.
  Duration get serverCooldownRemaining {
    final until = _cooldownUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(clock.nowUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Time left before the next request would respect the spacing rule.
  Duration get spacingRemaining {
    final last = _lastRequestAt;
    if (last == null) return Duration.zero;
    final ready = last.add(minInterval);
    final now = clock.nowUtc();
    return ready.isAfter(now) ? ready.difference(now) : Duration.zero;
  }

  /// Everything that would delay the next request.
  Duration get cooldownRemaining {
    final server = serverCooldownRemaining;
    final spacing = spacingRemaining;
    return server > spacing ? server : spacing;
  }

  bool get isCoolingDown => cooldownRemaining > Duration.zero;

  /// Reserves a request slot.
  ///
  /// Returns [Duration.zero] when the caller may proceed now. Otherwise returns
  /// the remaining wait without consuming the slot; the caller decides whether
  /// to wait (short spacing) or report a cooldown.
  Future<Duration> acquire({
    Duration maxWait = const Duration(milliseconds: 1200),
  }) async {
    var wait = _waitFor(clock.nowUtc());
    if (wait <= Duration.zero) {
      _lastRequestAt = clock.nowUtc();
      return Duration.zero;
    }
    if (wait > maxWait) return wait;
    await Future<void>.delayed(wait);
    wait = _waitFor(clock.nowUtc());
    if (wait > Duration.zero) return wait;
    _lastRequestAt = clock.nowUtc();
    return Duration.zero;
  }

  /// Used by provider adapters before every HTTP request.
  ///
  /// Throws a typed quota failure instead of blocking when the wait is long.
  Future<void> guard({
    Duration maxWait = const Duration(milliseconds: 1200),
  }) async {
    final wait = await acquire(maxWait: maxWait);
    if (wait > Duration.zero) {
      throw ProviderException(
        LookupFailureKind.cooldown,
        '$providerId is cooling down for ${wait.inSeconds}s.',
        retryAfter: wait,
      );
    }
  }

  /// Applies a server-provided cooldown (429, quota or reset header).
  void penalize(Duration duration) {
    if (duration <= Duration.zero) return;
    final until = clock.nowUtc().add(duration);
    final current = _cooldownUntil;
    if (current == null || until.isAfter(current)) _cooldownUntil = until;
  }

  Duration _waitFor(DateTime now) {
    var wait = spacingRemaining;
    final cooldown = serverCooldownRemaining;
    if (cooldown > wait) wait = cooldown;
    return wait;
  }
}
