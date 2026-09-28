import 'package:flutter/material.dart';
import 'package:lyberry/domain/validation.dart';
import 'package:lyberry/ui/theme.dart';

/// Half-star rating control.
///
/// Every star is one correctly centred glyph inside its own 48dp target: the
/// left half sets the half star, the right half the whole star. Assistive
/// technology gets slider semantics with increase and decrease actions.
class RatingInput extends StatelessWidget {
  const RatingInput({
    super.key,
    required this.rating,
    required this.onChanged,
    this.iconSize = 30,
  });

  final double? rating;
  final ValueChanged<double?> onChanged;
  final double iconSize;

  /// 5 stars x 48dp touch targets.
  static const double _starRowWidth = 5 * LyberryMetrics.touchTarget;

  @override
  Widget build(BuildContext context) {
    final value = rating;
    final double increase =
        RatingRules.snap(((value ?? 0) + 0.5).clamp(0.5, 5.0).toDouble()) ??
        RatingRules.min;
    final double? decrease = value == null
        ? null
        : RatingRules.snap(value - 0.5);

    return Semantics(
      slider: true,
      label: 'Rating',
      value: RatingRules.format(value),
      increasedValue: RatingRules.format(increase),
      decreasedValue: RatingRules.format(decrease),
      onIncrease: () => onChanged(increase),
      onDecrease: () => onChanged(decrease),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stars = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var index = 1; index <= 5; index++)
                _StarTarget(
                  index: index,
                  rating: value,
                  size: iconSize,
                  onChanged: onChanged,
                ),
            ],
          );
          final valueLabel = Text(
            RatingRules.format(value),
            style: const TextStyle(color: LyberryColors.muted, fontSize: 13),
          );
          final clearButton = value == null
              ? null
              : IconButton(
                  tooltip: 'Clear rating',
                  onPressed: () => onChanged(null),
                  icon: const Icon(Icons.close, size: 18),
                  color: LyberryColors.muted,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(
                      LyberryMetrics.touchTarget,
                      LyberryMetrics.touchTarget,
                    ),
                  ),
                );

          // On narrow phones the value and clear action move below the stars so
          // a rated row cannot overflow.
          final requiredInlineWidth =
              _starRowWidth + 6 + (clearButton == null ? 40 : 88);
          if (constraints.maxWidth >= requiredInlineWidth) {
            return Row(
              children: <Widget>[
                stars,
                const SizedBox(width: 6),
                Expanded(child: valueLabel),
                ?clearButton,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              stars,
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(child: valueLabel),
                  ?clearButton,
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StarTarget extends StatelessWidget {
  const _StarTarget({
    required this.index,
    required this.rating,
    required this.size,
    required this.onChanged,
  });

  final int index;
  final double? rating;
  final double size;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final value = rating;
    final fill = value == null ? 0.0 : (value - (index - 1)).clamp(0.0, 1.0);
    final icon = switch (fill) {
      >= 1 => Icons.star,
      > 0 => Icons.star_half,
      _ => Icons.star_border,
    };
    final half = index - 0.5;
    final full = index.toDouble();

    return SizedBox(
      width: LyberryMetrics.touchTarget,
      height: LyberryMetrics.touchTarget,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _RatingRegion(
                    key: Key('rating-$half'),
                    label: 'Rate ${RatingRules.format(half)} of 5',
                    isSelected: value == half,
                    onTap: () => onChanged(half),
                  ),
                ),
                Expanded(
                  child: _RatingRegion(
                    key: Key('rating-$full'),
                    label: 'Rate ${RatingRules.format(full)} of 5',
                    isSelected: value == full,
                    onTap: () => onChanged(full),
                  ),
                ),
              ],
            ),
          ),
          // Ignored for hit testing so taps always reach the regions below.
          IgnorePointer(
            child: Center(
              child: Icon(
                icon,
                size: size,
                color: fill > 0 ? LyberryColors.signal : LyberryColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RatingRegion extends StatelessWidget {
  const _RatingRegion({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: const SizedBox.expand(),
      ),
    );
  }
}
