import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/identifier.dart';

/// Turns the camera's repeated stream of detections into at most one lookup.
///
/// The camera is stopped before the handler runs, so a lookup never competes
/// with a live preview, and the same code within [debounce] is ignored. This is
/// plain, injectable logic so the scanner flow is unit-testable without a
/// camera or a device.
class ScanCoordinator {
  ScanCoordinator({
    required this.onIdentifier,
    required this.pauseCamera,
    required this.resumeCamera,
    this.debounce = const Duration(milliseconds: 1500),
    Clock? clock,
  }) : _clock = clock ?? const SystemClock();

  final Future<void> Function(NormalizedIdentifier identifier) onIdentifier;
  final Future<void> Function() pauseCamera;
  final Future<void> Function() resumeCamera;
  final Duration debounce;
  final Clock _clock;

  String? _lastValue;
  DateTime? _lastSeenAt;
  bool _handling = false;

  bool get isHandling => _handling;
  String? get lastValue => _lastValue;

  /// Returns true when this detection was accepted for a lookup.
  Future<bool> onDetected(String raw) async {
    if (_handling) return false;
    final identifier = IdentifierNormalizer.tryNormalize(raw);
    if (identifier == null) return false;
    return submit(identifier);
  }

  /// Shared entry point for camera detections and manual submissions, so both
  /// paths respect the same in-flight guard and debounce window.
  Future<bool> submit(NormalizedIdentifier identifier) async {
    if (_handling) return false;
    final now = _clock.nowUtc();
    final lastSeen = _lastSeenAt;
    if (_lastValue == identifier.value &&
        lastSeen != null &&
        now.difference(lastSeen) < debounce) {
      return false;
    }

    _handling = true;
    _lastValue = identifier.value;
    _lastSeenAt = now;
    try {
      await pauseCamera();
      await onIdentifier(identifier);
      return true;
    } finally {
      _handling = false;
    }
  }

  /// Called when the scanner screen becomes visible again after a lookup.
  Future<void> resume() async {
    _lastSeenAt = null;
    await resumeCamera();
  }
}
