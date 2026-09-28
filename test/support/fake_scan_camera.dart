import 'package:flutter/widgets.dart';
import 'package:lyberry/services/scan_camera.dart';

/// Camera double for scanner tests: records lifecycle calls and can emit codes.
class FakeScanCamera implements ScanCamera {
  FakeScanCamera({this.previewError});

  /// Error the preview reports through `onError`, exactly like
  /// `MobileScanner.errorBuilder` does for a denied camera permission. Lets
  /// tests render the real camera-unavailable fallback without hardware.
  final Object? previewError;

  int starts = 0;
  int stops = 0;
  int disposes = 0;
  bool _running = false;
  ValueChanged<String>? _onDetected;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    starts++;
    _running = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    _running = false;
  }

  @override
  Future<void> dispose() async {
    disposes++;
    _running = false;
  }

  @override
  Widget buildPreview(
    BuildContext context, {
    required ValueChanged<String> onDetected,
    required Widget Function(BuildContext context, Object? error) onError,
  }) {
    _onDetected = onDetected;
    final error = previewError;
    if (error != null) return onError(context, error);
    return const ColoredBox(color: Color(0xFF000000));
  }

  /// Simulates the camera reporting a code.
  void emit(String code) => _onDetected?.call(code);
}
