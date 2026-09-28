import 'package:flutter/material.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/ui/theme.dart';

/// Wrapping medium filter: two rows on a normal phone, more when text is large.
class MediumTabs extends StatelessWidget {
  const MediumTabs({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  /// `null` selects All.
  final MediaType? selected;
  final ValueChanged<MediaType?> onSelected;

  @override
  Widget build(BuildContext context) {
    final entries = <(String, MediaType?)>[
      ('All', null),
      for (final medium in MediaType.values) (medium.pluralLabel, medium),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (var index = 0; index < entries.length; index++) ...<Widget>[
              _MediumTab(
                label: entries[index].$1,
                isSelected: entries[index].$2 == selected,
                onTap: () => onSelected(entries[index].$2),
              ),
              if (index != entries.length - 1)
                Container(
                  width: 1,
                  height: 20,
                  color: LyberryColors.rule,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                ),
            ],
          ],
        ),
        const Divider(height: 1),
      ],
    );
  }
}

class _MediumTab extends StatelessWidget {
  const _MediumTab({
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
      label: '$label filter',
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: LyberryMetrics.touchTarget,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: IntrinsicWidth(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: isSelected
                          ? LyberryColors.signal
                          : LyberryColors.ink,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    height: 2,
                    color: isSelected
                        ? LyberryColors.signal
                        : Colors.transparent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
