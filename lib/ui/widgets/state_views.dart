import 'package:flutter/material.dart';
import 'package:lyberry/ui/theme.dart';

/// Reusable centered message block for empty, no-result and error states.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.primaryAction,
    this.secondaryAction,
    this.iconColor = LyberryColors.muted,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? primaryAction;
  final Widget? secondaryAction;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 40, color: iconColor),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: LyberryType.display(size: 18, weight: 600),
          ),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: LyberryType.bodyMuted),
          if (primaryAction != null) ...<Widget>[
            const SizedBox(height: 20),
            primaryAction!,
          ],
          if (secondaryAction != null) ...<Widget>[
            const SizedBox(height: 4),
            secondaryAction!,
          ],
        ],
      ),
    );
  }
}

class LoadingLibraryView extends StatelessWidget {
  const LoadingLibraryView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: <Widget>[
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(height: 16),
          Text('Opening your library', style: LyberryType.bodyMuted),
        ],
      ),
    );
  }
}
