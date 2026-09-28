import 'package:flutter/material.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/scan_camera.dart';
import 'package:lyberry/services/scan_coordinator.dart';
import 'package:lyberry/state/item_draft.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/navigation.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Real barcode capture with an always-available manual path.
///
/// This screen is the only camera lifecycle owner: the plugin's own lifecycle
/// handling and auto-start are off, and start/stop is decided from the app
/// lifecycle, route visibility and whether a lookup is in flight.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.camera});

  /// Injected by tests; the real screen builds a [MobileScannerCamera].
  final ScanCamera? camera;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  final TextEditingController _manual = TextEditingController();
  late final ScanCamera _camera;
  late final bool _ownsCamera;
  ScanCoordinator? _coordinator;
  bool _appResumed = true;
  bool _routeVisible = true;
  bool _permissionBlocked = false;
  bool _disposed = false;
  String? _lastCode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsCamera = widget.camera == null;
    _camera = widget.camera ?? MobileScannerCamera();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_coordinator != null) return;
    _coordinator = ScanCoordinator(
      onIdentifier: _handleIdentifier,
      pauseCamera: () async {
        _routeVisible = false;
        await _camera.stop();
      },
      resumeCamera: () async {
        _routeVisible = true;
        await _syncCamera();
      },
      clock: AppServicesScope.of(context).clock,
    );
    _syncCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _syncCamera();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _manual.dispose();
    if (_ownsCamera) _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          LyberryMetrics.gutter,
          12,
          LyberryMetrics.gutter,
          28,
        ),
        children: <Widget>[
          _viewfinder(context),
          const SizedBox(height: 10),
          Text(
            _statusLine(),
            key: const Key('scan-status'),
            style: LyberryType.bodyMuted,
          ),
          const SizedBox(height: 22),
          Text('TYPE THE CODE', style: LyberryType.eyebrow()),
          const SizedBox(height: 8),
          TextField(
            key: const Key('scan-manual-field'),
            controller: _manual,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'ISBN or barcode',
              helperText:
                  'Looking up a code needs a network connection. Adding a copy '
                  'by hand always works.',
              helperStyle: LyberryType.bodyMuted,
              // Without an explicit limit the decorator keeps the helper on one
              // ellipsised line, which clipped this sentence mid-word on a
              // large-text device. Four lines cover the full sentence down to a
              // 320px-wide phone at 1.6x text; shorter cases still use fewer.
              helperMaxLines: 4,
            ),
            onSubmitted: (_) => _submitManual(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('scan-manual-lookup'),
            onPressed: _submitManual,
            icon: const Icon(Icons.search, size: 18),
            label: const Text('Look up'),
          ),
          TextButton(
            key: const Key('scan-manual-add'),
            onPressed: () => openEditor(context),
            child: const Text('Add a copy by hand instead'),
          ),
          const SizedBox(height: 12),
          Text(
            'Looking up a code sends only that code to the metadata providers. '
            'Your notes, reviews and photos are never sent.',
            style: LyberryType.bodyMuted,
          ),
        ],
      ),
    );
  }

  Widget _viewfinder(BuildContext context) {
    // Keep the preview square but bounded, so the manual fallback stays visible
    // on short phones and at large text sizes.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.42;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: AspectRatio(
        aspectRatio: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: LyberryColors.surface,
            border: Border.all(color: LyberryColors.rule),
            borderRadius: BorderRadius.circular(LyberryMetrics.corner),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(LyberryMetrics.corner),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (_permissionBlocked)
                  _cameraUnavailable()
                else
                  _camera.buildPreview(
                    context,
                    onDetected: _onDetected,
                    onError: (context, error) =>
                        _cameraUnavailable(error: error),
                  ),
                IgnorePointer(
                  child: Center(
                    child: FractionallySizedBox(
                      widthFactor: 0.72,
                      child: Container(
                        height: 96,
                        decoration: BoxDecoration(
                          border: Border.all(color: LyberryColors.signal),
                          borderRadius: BorderRadius.circular(
                            LyberryMetrics.corner,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cameraUnavailable({Object? error}) {
    final permission =
        error is MobileScannerException &&
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              permission ? Icons.no_photography_outlined : Icons.videocam_off,
              color: LyberryColors.muted,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              permission ? 'Camera access is off' : 'The camera is unavailable',
              textAlign: TextAlign.center,
              style: LyberryType.display(size: 16, weight: 600),
            ),
            const SizedBox(height: 6),
            Text(
              'Type the ISBN or barcode below instead.',
              textAlign: TextAlign.center,
              style: LyberryType.bodyMuted,
            ),
          ],
        ),
      ),
    );
  }

  String _statusLine() {
    if (_permissionBlocked) {
      return 'Camera permission is off | manual entry still works.';
    }
    final last = _lastCode;
    if (last != null) return 'Last code: $last';
    return 'Point the camera at the barcode, or type the code below.';
  }

  void _onDetected(String raw) {
    _coordinator?.onDetected(raw);
  }

  Future<void> _handleIdentifier(NormalizedIdentifier identifier) async {
    if (!mounted) return;
    setState(() => _lastCode = identifier.value);

    final choice = await Navigator.of(context).push<LookupChoice>(
      MaterialPageRoute<LookupChoice>(
        builder: (_) =>
            CandidatesScreen(query: LookupQuery(identifier: identifier)),
      ),
    );
    if (!mounted) return;

    switch (choice) {
      case UseCandidate(:final candidate):
        await openEditor(
          context,
          prefill: ItemDraft.fromCandidate(
            candidate,
            barcode: identifier.value,
          ),
          coverUrl: candidate.coverUrl,
        );
      case AddManually():
        await openEditor(
          context,
          prefill: ItemDraft(
            medium: MediaType.book,
            title: '',
            barcode: identifier.value,
          ),
        );
      case null:
        break;
    }
    if (mounted) await _coordinator?.resume();
  }

  Future<void> _submitManual() async {
    final identifier = IdentifierNormalizer.tryNormalize(_manual.text);
    if (identifier == null) {
      showMessage(
        context,
        'Enter a valid ISBN-10, ISBN-13, EAN-13, EAN-8 or UPC-A code.',
      );
      return;
    }
    // Manual submissions use the same guard as camera detections, so rapid taps
    // cannot start two lookups.
    await _coordinator?.submit(identifier);
  }

  /// Starts or stops the camera so it matches app visibility and route state.
  Future<void> _syncCamera() async {
    if (_disposed || !mounted) return;
    final shouldRun = _appResumed && _routeVisible;
    try {
      if (shouldRun) {
        await _camera.start();
      } else {
        await _camera.stop();
      }
    } on MobileScannerException catch (error) {
      if (!mounted) return;
      setState(() {
        _permissionBlocked =
            error.errorCode == MobileScannerErrorCode.permissionDenied;
      });
    } on Object {
      // A camera that cannot start leaves the manual path in place.
    }
  }
}
