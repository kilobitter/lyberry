import 'package:flutter_test/flutter_test.dart';
import 'package:lyberry/services/games/games_request_gate.dart';
import 'package:lyberry/services/rate_limiter.dart';

void main() {
  GamesRequestGate gate({
    Duration minInterval = Duration.zero,
    int maxConcurrent = 6,
  }) => GamesRequestGate(
    limiter: ProviderRateLimiter(providerId: 'igdb', minInterval: minInterval),
    maxConcurrent: maxConcurrent,
  );

  test('spaces consecutive requests', () async {
    final subject = gate(minInterval: const Duration(milliseconds: 250));
    final watch = Stopwatch()..start();
    await subject.run(() async => 1);
    await subject.run(() async => 2);
    watch.stop();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(200));
  });

  test('never exceeds the concurrency cap', () async {
    final subject = gate(maxConcurrent: 2);
    var peak = 0;
    Future<void> task() => subject.run(() async {
      if (subject.active > peak) peak = subject.active;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });

    final watch = Stopwatch()..start();
    await Future.wait<void>(<Future<void>>[task(), task(), task(), task()]);
    watch.stop();

    expect(peak, lessThanOrEqualTo(2));
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(150));
  });

  test('a server cooldown blocks every later request', () async {
    final subject = gate();
    subject.penalize(const Duration(milliseconds: 300));
    expect(subject.cooldownRemaining, greaterThan(Duration.zero));

    final watch = Stopwatch()..start();
    await subject.run(() async => 1);
    watch.stop();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(200));
  });
}
