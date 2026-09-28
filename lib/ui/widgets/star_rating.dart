import 'package:flutter/material.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/ui/theme.dart';

/// Read-only half-star display with the numeric value beside it.
class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.rating,
    this.iconSize = 16,
    this.showValue = true,
    this.mutedColor = LyberryColors.muted,
  });

  final double? rating;
  final double iconSize;
  final bool showValue;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    final value = rating;
    final semantics = value == null
        ? 'Not rated'
        : 'Rated ${RatingRules.format(value)} out of 5';
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var index = 1; index <= 5; index++)
            _Star(value: value, index: index, size: iconSize),
          if (showValue) ...<Widget>[
            SizedBox(width: iconSize * 0.35),
            Text(
              value == null ? '--' : RatingRules.format(value),
              style: TextStyle(
                fontSize: iconSize * 0.82,
                color: LyberryColors.ink,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Star extends StatelessWidget {
  const _Star({required this.value, required this.index, required this.size});

  final double? value;
  final int index;
  final double size;

  @override
  Widget build(BuildContext context) {
    final rating = value;
    final fill = rating == null ? 0.0 : (rating - (index - 1)).clamp(0.0, 1.0);
    final icon = switch (fill) {
      >= 1 => Icons.star,
      > 0 => Icons.star_half,
      _ => Icons.star_border,
    };
    return Icon(
      icon,
      size: size,
      color: fill > 0 ? LyberryColors.signal : LyberryColors.muted,
    );
  }
}
