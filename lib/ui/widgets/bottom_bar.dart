import 'package:flutter/material.dart';
import 'package:lyberry/ui/theme.dart';

/// Library / Scan / Settings bar with the scan action kept visually dominant.
class LyberryBottomBar extends StatelessWidget {
  const LyberryBottomBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.onScan,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    // The bar grows with the text scale so labels never clip or overflow.
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    final itemHeight = 52.0 + (scale - 1) * 16;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: LyberryColors.background,
        border: Border(top: BorderSide(color: LyberryColors.rule)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: _BarItem(
                  key: const Key('nav-library'),
                  icon: Icons.library_books_outlined,
                  label: 'Library',
                  height: itemHeight,
                  isSelected: selectedIndex == 0,
                  onTap: () => onSelect(0),
                ),
              ),
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: FilledButton.icon(
                    key: const Key('nav-scan'),
                    onPressed: onScan,
                    icon: const Icon(Icons.barcode_reader, size: 22),
                    label: const Text('Scan', maxLines: 1),
                    style: FilledButton.styleFrom(
                      foregroundColor: LyberryColors.ink,
                      minimumSize: Size(0, itemHeight),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(26)),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _BarItem(
                  key: const Key('nav-settings'),
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  height: itemHeight,
                  isSelected: selectedIndex == 1,
                  onTap: () => onSelect(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.height,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final double height;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? LyberryColors.ink : LyberryColors.muted;
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(LyberryMetrics.corner),
        child: SizedBox(
          height: height,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              // Shrinks rather than clipping the label on narrow, large-text phones.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
              const SizedBox(height: 3),
              Container(
                height: 2,
                width: 22,
                color: isSelected ? LyberryColors.signal : Colors.transparent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
