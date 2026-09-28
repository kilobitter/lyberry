/// Injectable clock so timestamps are deterministic in tests.
abstract interface class Clock {
  DateTime nowUtc();
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

class FixedClock implements Clock {
  FixedClock(this._now);

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void advance(Duration duration) => _now = _now.add(duration);

  set value(DateTime next) => _now = next.toUtc();
}
