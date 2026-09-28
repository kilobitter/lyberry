import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/ui/theme.dart';

/// Cover art for one copy: the stored image when there is one, otherwise a
/// medium-specific geometric mark. Never distorts or crops the real artwork.
class MediaCover extends StatelessWidget {
  const MediaCover({
    super.key,
    required this.medium,
    this.image,
    this.semanticLabel,
    this.cacheWidth,
  });

  final MediaType medium;
  final Future<MediaAsset?>? image;
  final String? semanticLabel;

  /// Decode width in pixels, so tiles never hold a full-size raster.
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final future = image;
    if (future == null) return _placeholder();
    return FutureBuilder<MediaAsset?>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data?.bytes;
        if (bytes == null || bytes.isEmpty) return _placeholder();
        return ClipRRect(
          borderRadius: BorderRadius.circular(LyberryMetrics.corner),
          child: ColoredBox(
            color: LyberryColors.surface,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              cacheWidth: cacheWidth,
              semanticLabel: semanticLabel,
              errorBuilder: (context, error, stack) => _placeholder(),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder() =>
      CoverPlaceholder(medium: medium, semanticLabel: semanticLabel);
}

/// Squared, medium-specific placeholder used when a copy has no cover image.
class CoverPlaceholder extends StatelessWidget {
  const CoverPlaceholder({super.key, required this.medium, this.semanticLabel});

  final MediaType medium;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel ?? '${medium.label} cover placeholder',
      image: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: LyberryColors.surface,
          border: Border.all(color: LyberryColors.rule),
          borderRadius: BorderRadius.circular(LyberryMetrics.corner),
        ),
        child: CustomPaint(
          painter: _CoverPlaceholderPainter(medium),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _CoverPlaceholderPainter extends CustomPainter {
  const _CoverPlaceholderPainter(this.medium);

  final MediaType medium;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final unit = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final accent = Paint()
      ..color = LyberryColors.signal
      ..style = PaintingStyle.fill;
    final line = Paint()
      ..color = LyberryColors.muted
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, unit * 0.012);

    switch (medium) {
      case MediaType.book:
        final barWidth = unit * 0.09;
        final gap = unit * 0.05;
        final heights = <double>[0.42, 0.52, 0.34];
        for (var index = 0; index < heights.length; index++) {
          final height = unit * heights[index];
          final left =
              center.dx - (barWidth * 1.5 + gap) + index * (barWidth + gap);
          final rect = RRect.fromRectAndRadius(
            Rect.fromLTWH(left, center.dy - height / 2, barWidth, height),
            const Radius.circular(2),
          );
          canvas.drawRRect(rect, index == 1 ? accent : line);
        }
      case MediaType.cd:
        canvas.drawCircle(center, unit * 0.24, line);
        canvas.drawCircle(center, unit * 0.06, accent);
        canvas.drawLine(
          Offset(center.dx - unit * 0.3, center.dy),
          Offset(center.dx - unit * 0.26, center.dy),
          line,
        );
      case MediaType.dvd:
        canvas.drawCircle(center, unit * 0.26, line);
        canvas.drawCircle(
          Offset(center.dx + unit * 0.12, center.dy + unit * 0.1),
          unit * 0.05,
          accent,
        );
        canvas.drawCircle(center, unit * 0.05, line);
      case MediaType.bluray:
        canvas.drawCircle(center, unit * 0.26, line);
        final slash = Paint()
          ..color = LyberryColors.signal
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.6, unit * 0.03);
        canvas.drawLine(
          Offset(center.dx - unit * 0.2, center.dy + unit * 0.2),
          Offset(center.dx + unit * 0.2, center.dy - unit * 0.2),
          slash,
        );
        canvas.drawCircle(center, unit * 0.05, line);
      case MediaType.vinyl:
        canvas.drawCircle(center, unit * 0.28, line);
        canvas.drawCircle(center, unit * 0.18, line);
        canvas.drawCircle(center, unit * 0.055, accent);
      case MediaType.game:
        final radius = unit * 0.3;
        final hexagon = Path();
        for (var index = 0; index < 6; index++) {
          final angle = math.pi / 3 * index - math.pi / 6;
          final point = Offset(
            center.dx + radius * math.cos(angle),
            center.dy + radius * math.sin(angle),
          );
          index == 0
              ? hexagon.moveTo(point.dx, point.dy)
              : hexagon.lineTo(point.dx, point.dy);
        }
        hexagon.close();
        canvas.drawPath(hexagon, line);
        canvas.drawCircle(center, unit * 0.06, accent);
    }

    final label = TextPainter(
      text: TextSpan(
        text: medium.label.toUpperCase(),
        style: LyberryType.display(
          size: math.max(8, unit * 0.055),
          weight: 600,
          letterSpacing: 1.6,
          color: LyberryColors.muted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - unit * 0.16);
    label.paint(
      canvas,
      Offset(unit * 0.09, size.height - label.height - unit * 0.09),
    );
  }

  @override
  bool shouldRepaint(covariant _CoverPlaceholderPainter oldDelegate) =>
      oldDelegate.medium != medium;
}
