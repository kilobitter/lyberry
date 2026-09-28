import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lyberry/domain/cover_crop.dart';
import 'package:lyberry/domain/cover_renderer.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/services/image_transform.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/theme.dart';

/// Dedicated crop preview shared by every cover-from-photo path.
///
/// The stage always shows the orientation-corrected, quarter-turned image, the
/// exact space [CoverCrop] coordinates are expressed in, so the rectangle the
/// user frames is the rectangle that gets saved. Applying pops a validated,
/// derived [MediaAsset]; cancelling pops null and touches nothing.
class CoverCropScreen extends StatefulWidget {
  const CoverCropScreen({
    super.key,
    required this.sourceBytes,
    required this.transform,
    this.title = 'Use photo as cover',
  });

  /// The untouched original photo bytes.
  final Uint8List sourceBytes;
  final ImageTransformService transform;
  final String title;

  static const Key rotateLeftKey = Key('crop-rotate-left');
  static const Key rotateRightKey = Key('crop-rotate-right');
  static const Key resetKey = Key('crop-reset');
  static const Key applyKey = Key('crop-apply');
  static const Key cancelKey = Key('crop-cancel');
  static const Key stageKey = Key('crop-stage');

  @override
  State<CoverCropScreen> createState() => _CoverCropScreenState();
}

class _CoverCropScreenState extends State<CoverCropScreen> {
  CoverPreview? _oriented;
  CoverPreview? _preview;
  CoverCrop _crop = CoverCrop.full;
  int _turns = 0;
  bool _loading = true;
  bool _applying = false;
  String? _error;
  int _requestSeq = 0;
  bool _closing = false;
  bool _disposed = false;

  bool get _busy => _loading || _applying || _preview == null;

  /// True once this route has been asked to leave, including while the reverse
  /// transition is still animating. A render that finishes after Cancel must
  /// never pop the route underneath this one.
  bool get _leaving => _closing || _disposed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Leaves the screen at most once, so a late result cannot pop twice.
  void _close([MediaAsset? result]) {
    if (_leaving || !mounted) return;
    _closing = true;
    final navigator = Navigator.of(context);
    if (result == null) {
      unawaited(navigator.maybePop());
    } else {
      navigator.pop(result);
    }
  }

  Future<void> _load() async {
    if (_leaving) return;
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await widget.transform.preview(widget.sourceBytes);
      if (_disposed || seq != _requestSeq) return;
      setState(() {
        _oriented = preview;
        _preview = preview;
        _turns = 0;
        _crop = CoverCrop.full;
        _loading = false;
      });
    } on Object catch (error) {
      if (_disposed || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = describeFailure(error);
      });
    }
  }

  /// Turns the preview and starts a fresh full-frame crop for that orientation.
  Future<void> _rotateTo(int quarterTurns) async {
    final oriented = _oriented;
    if (oriented == null || _loading || _applying || _leaving) return;
    final turns = ((quarterTurns % 4) + 4) % 4;
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = turns == 0
          ? oriented
          : await widget.transform.rotate(oriented.bytes, turns);
      if (_disposed || seq != _requestSeq) return;
      setState(() {
        _turns = turns;
        _crop = CoverCrop.full;
        _preview = preview;
        _loading = false;
      });
    } on Object catch (error) {
      if (_disposed || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = describeFailure(error);
      });
    }
  }

  Future<void> _reset() => _rotateTo(0);

  Future<void> _apply() async {
    if (_busy || _leaving) return;
    final crop = _crop.copyWith(quarterTurns: _turns);
    final issues = crop.validate();
    if (issues.isNotEmpty) {
      setState(() => _error = issues.first.message);
      return;
    }
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final asset = await widget.transform.deriveCover(
        source: widget.sourceBytes,
        crop: crop,
      );
      if (_leaving || !mounted) return;
      // The route must still be the one on top: if the user left while the
      // render ran, the result belongs to a draft nobody is looking at.
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      _close(asset);
    } on Object catch (error) {
      if (_leaving || !mounted) return;
      // The previous cover stays in place: applying failed before the pop.
      setState(() {
        _applying = false;
        _error = describeFailure(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // A back gesture or system back also claims the route, so a render that
        // is still running cannot pop a second time.
        if (didPop) _closing = true;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: CoverCropScreen.cancelKey,
            tooltip: 'Cancel',
            onPressed: () => _close(),
            icon: const Icon(Icons.close),
          ),
          title: Text(widget.title),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LyberryMetrics.gutter,
                    8,
                    LyberryMetrics.gutter,
                    8,
                  ),
                  child: _stage(preview),
                ),
              ),
              if (_error != null && preview != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LyberryMetrics.gutter,
                    0,
                    LyberryMetrics.gutter,
                    8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      key: const Key('crop-error'),
                      style: const TextStyle(
                        color: LyberryColors.signal,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              _controls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stage(CoverPreview? preview) {
    if (preview == null) {
      if (_error != null) return _errorState();
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: CropStage(
            key: CoverCropScreen.stageKey,
            imageBytes: preview.bytes,
            imageWidth: preview.width,
            imageHeight: preview.height,
            crop: _crop,
            enabled: !_busy,
            onChanged: (value) => setState(() => _crop = value),
          ),
        ),
        if (_busy)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x88101010),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  /// A failed preview is a stable state, not a spinner: the user can retry the
  /// load or leave, and the old cover is untouched either way.
  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LyberryMetrics.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.broken_image_outlined,
              size: 40,
              color: LyberryColors.muted,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const Key('crop-error'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: LyberryColors.signal, fontSize: 14),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key('crop-error-cancel'),
                  onPressed: _leaving ? null : () => _close(),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Cancel'),
                ),
                FilledButton.icon(
                  key: const Key('crop-error-retry'),
                  onPressed: _loading || _leaving ? null : _load,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    final canInteract = !_busy && !_leaving;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LyberryMetrics.gutter,
        4,
        LyberryMetrics.gutter,
        12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                key: CoverCropScreen.rotateLeftKey,
                onPressed: canInteract ? () => _rotateTo(_turns - 1) : null,
                icon: const Icon(Icons.rotate_left, size: 18),
                label: const Text('Rotate left'),
              ),
              OutlinedButton.icon(
                key: CoverCropScreen.rotateRightKey,
                onPressed: canInteract ? () => _rotateTo(_turns + 1) : null,
                icon: const Icon(Icons.rotate_right, size: 18),
                label: const Text('Rotate right'),
              ),
              TextButton.icon(
                key: CoverCropScreen.resetKey,
                onPressed: canInteract ? _reset : null,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: CoverCropScreen.applyKey,
            onPressed: canInteract ? _apply : null,
            icon: _applying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check, size: 18),
            label: const Text('Use as cover'),
          ),
        ],
      ),
    );
  }
}

/// The interactive stage: the photo plus a draggable, resizable crop rectangle.
class CropStage extends StatefulWidget {
  const CropStage({
    super.key,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.crop,
    required this.onChanged,
    this.enabled = true,
  });

  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;
  final CoverCrop crop;
  final ValueChanged<CoverCrop> onChanged;
  final bool enabled;

  @override
  State<CropStage> createState() => _CropStageState();
}

enum _DragMode { move, topLeft, topRight, bottomLeft, bottomRight }

class _CropStageState extends State<CropStage> {
  /// Logical size of a corner handle and its touch target.
  static const double handleSize = 28;

  /// Smallest crop side in logical pixels, so a drag can never vanish.
  static const double minSide = 40;

  _DragMode? _mode;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final fitted = _fitRect(
          box,
          Size(widget.imageWidth.toDouble(), widget.imageHeight.toDouble()),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Report the touch-down point: a finger on a corner handle must
          // resize from where it landed, not from the slop-exceeded point.
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: widget.enabled
              ? (details) => _start(details.localPosition, fitted)
              : null,
          onPanUpdate: widget.enabled
              ? (details) => _update(details.delta, fitted)
              : null,
          onPanEnd: widget.enabled ? (_) => _mode = null : null,
          onPanCancel: widget.enabled ? () => _mode = null : null,
          child: Stack(
            children: <Widget>[
              Positioned.fromRect(
                rect: fitted,
                child: Image.memory(
                  widget.imageBytes,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  semanticLabel: 'Photo to crop',
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _CropPainter(
                    rect: _pixelRect(fitted),
                    handleSize: handleSize,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _start(Offset position, Rect fitted) {
    final rect = _pixelRect(fitted);
    final mode = _hitTest(position, rect);
    if (mode == null) return;
    setState(() => _mode = mode);
  }

  void _update(Offset delta, Rect fitted) {
    final mode = _mode;
    if (mode == null || fitted.isEmpty) return;
    widget.onChanged(_applyDrag(mode, delta, fitted));
  }

  CoverCrop _applyDrag(_DragMode mode, Offset delta, Rect fitted) {
    final crop = widget.crop;
    final dx = delta.dx / fitted.width;
    final dy = delta.dy / fitted.height;
    final minX = (minSide / fitted.width).clamp(0.0, 1.0);
    final minY = (minSide / fitted.height).clamp(0.0, 1.0);

    var left = crop.left;
    var top = crop.top;
    var right = crop.left + crop.width;
    var bottom = crop.top + crop.height;

    // Moving keeps the rectangle's size; it slides until it meets an edge.
    if (mode == _DragMode.move) {
      final width = (right - left).clamp(minX, 1.0);
      final height = (bottom - top).clamp(minY, 1.0);
      final movedLeft = (left + dx).clamp(0.0, 1.0 - width);
      final movedTop = (top + dy).clamp(0.0, 1.0 - height);
      return crop.copyWith(
        left: movedLeft,
        top: movedTop,
        width: width,
        height: height,
      );
    }

    switch (mode) {
      case _DragMode.topLeft:
        left += dx;
        top += dy;
      case _DragMode.topRight:
        right += dx;
        top += dy;
      case _DragMode.bottomLeft:
        left += dx;
        bottom += dy;
      case _DragMode.bottomRight:
        right += dx;
        bottom += dy;
      case _DragMode.move:
        break; // Handled above.
    }

    // Clamp the anchor edges first, so a stage smaller than the minimum crop
    // can never invert a clamp range and throw.
    left = left.clamp(0.0, 1.0 - minX);
    top = top.clamp(0.0, 1.0 - minY);
    right = right.clamp(left + minX, 1.0);
    bottom = bottom.clamp(top + minY, 1.0);

    return crop.copyWith(
      left: left,
      top: top,
      width: right - left,
      height: bottom - top,
    );
  }

  _DragMode? _hitTest(Offset position, Rect rect) {
    final corners = <(_DragMode, Offset)>[
      (_DragMode.topLeft, rect.topLeft),
      (_DragMode.topRight, rect.topRight),
      (_DragMode.bottomLeft, rect.bottomLeft),
      (_DragMode.bottomRight, rect.bottomRight),
    ];
    for (final (mode, corner) in corners) {
      if ((position - corner).distance <= handleSize) return mode;
    }
    if (rect.contains(position)) return _DragMode.move;
    return null;
  }

  Rect _pixelRect(Rect fitted) => Rect.fromLTWH(
    fitted.left + widget.crop.left * fitted.width,
    fitted.top + widget.crop.top * fitted.height,
    widget.crop.width * fitted.width,
    widget.crop.height * fitted.height,
  );

  /// The letterboxed rect an image occupies under `BoxFit.contain`.
  static Rect _fitRect(Size box, Size image) {
    if (box.isEmpty || image.isEmpty) return Rect.zero;
    final scale = (box.width / image.width) < (box.height / image.height)
        ? box.width / image.width
        : box.height / image.height;
    final size = Size(image.width * scale, image.height * scale);
    return Rect.fromLTWH(
      (box.width - size.width) / 2,
      (box.height - size.height) / 2,
      size.width,
      size.height,
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter({required this.rect, required this.handleSize});

  final Rect rect;
  final double handleSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || rect.isEmpty) return;
    final shade = Paint()..color = const Color(0x99000000);
    // Four bands around the crop keep the chosen pixels readable.
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), shade);
    canvas.drawRect(
      Rect.fromLTRB(0, rect.bottom, size.width, size.height),
      shade,
    );
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), shade);
    canvas.drawRect(
      Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom),
      shade,
    );

    final frame = Paint()
      ..color = LyberryColors.signal
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, frame);

    final grid = Paint()
      ..color = const Color(0x66F3F4EE)
      ..strokeWidth = 1;
    for (var index = 1; index < 3; index++) {
      final dx = rect.left + rect.width * index / 3;
      final dy = rect.top + rect.height * index / 3;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, dy), Offset(rect.right, dy), grid);
    }

    final handle = Paint()
      ..color = LyberryColors.signal
      ..style = PaintingStyle.fill;
    final half = handleSize * 0.18;
    for (final corner in <Offset>[
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: corner, width: half * 2, height: half * 2),
          const Radius.circular(3),
        ),
        handle,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.handleSize != handleSize;
}
