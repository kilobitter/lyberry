import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Camera seam for the scanner screen.
///
/// The real implementation owns exactly one `MobileScannerController` with
/// `autoStart: false`, and reports the plugin's *actual* running state, so the
/// screen can be the single lifecycle owner and tests can run without hardware.
abstract interface class ScanCamera {
  Widget buildPreview(
    BuildContext context, {
    required ValueChanged<String> onDetected,
    required Widget Function(BuildContext context, Object? error) onError,
  });

  Future<void> start();

  Future<void> stop();

  Future<void> dispose();

  bool get isRunning;
}

class MobileScannerCamera implements ScanCamera {
  MobileScannerCamera({
    List<BarcodeFormat> formats = defaultFormats,
    DetectionSpeed detectionSpeed = DetectionSpeed.noDuplicates,
  }) : _controller = MobileScannerController(
         autoStart: false,
         detectionSpeed: detectionSpeed,
         formats: formats,
       );

  /// The barcode families Lyberry can normalize.
  static const List<BarcodeFormat> defaultFormats = <BarcodeFormat>[
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.code128,
    BarcodeFormat.itf14,
  ];

  final MobileScannerController _controller;

  @override
  bool get isRunning => _controller.value.isRunning;

  @override
  Future<void> start() async {
    final state = _controller.value;
    if (state.isRunning || state.isStarting) return;
    await _controller.start();
  }

  @override
  Future<void> stop() async {
    final state = _controller.value;
    if (!state.isRunning && !state.isStarting) return;
    try {
      await _controller.stop();
    } on Object {
      // Stopping an already-stopped camera is not user-visible.
    }
  }

  @override
  Future<void> dispose() => _controller.dispose();

  @override
  Widget buildPreview(
    BuildContext context, {
    required ValueChanged<String> onDetected,
    required Widget Function(BuildContext context, Object? error) onError,
  }) {
    return MobileScanner(
      controller: _controller,
      fit: BoxFit.cover,
      // The screen owns start/stop; the plugin must not race it.
      useAppLifecycleState: false,
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (value != null && value.isNotEmpty) onDetected(value);
        }
      },
      errorBuilder: (context, error) => onError(context, error),
    );
  }
}
