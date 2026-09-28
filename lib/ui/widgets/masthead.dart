import 'package:flutter/material.dart';
import 'package:lyberry/ui/theme.dart';

/// Compact brand masthead: wordmark, rule, eyebrow and the add action.
class LyberryMasthead extends StatelessWidget {
  const LyberryMasthead({super.key, required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Text('Lyberry', style: LyberryType.display(size: 26, weight: 700)),
        const SizedBox(width: 12),
        Container(width: 1, height: 34, color: LyberryColors.rule),
        const SizedBox(width: 12),
        const Expanded(
          // Scales down instead of breaking words when text is enlarged.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'PHYSICAL\nMEDIA\nMATTERS',
              style: TextStyle(
                fontSize: 9,
                height: 1.35,
                letterSpacing: 1.6,
                color: LyberryColors.muted,
              ),
            ),
          ),
        ),
        IconButton(
          key: const Key('home-add-button'),
          tooltip: 'Add a copy',
          onPressed: onAdd,
          iconSize: 30,
          color: LyberryColors.signal,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

/// Small uppercase section label with an optional trailing detail.
class SectionLabel extends StatelessWidget {
  const SectionLabel({super.key, required this.label, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final detail = trailing;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LyberryType.eyebrow(),
          ),
        ),
        if (detail != null)
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LyberryType.eyebrow(),
          ),
      ],
    );
  }
}
