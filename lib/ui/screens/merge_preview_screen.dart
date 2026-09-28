import 'package:flutter/material.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/library_scope.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/masthead.dart';

/// Shows exactly what an import will do before anything is written.
class MergePreviewScreen extends StatefulWidget {
  const MergePreviewScreen({super.key, required this.preview});

  final BackupImportPreview preview;

  @override
  State<MergePreviewScreen> createState() => _MergePreviewScreenState();
}

class _MergePreviewScreenState extends State<MergePreviewScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final megabytes = preview.byteLength / (1024 * 1024);
    return PopScope(
      // While the single transaction runs, back must not detach this screen:
      // the merge could still commit and the caller would report a false
      // cancellation.
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Import backup')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            LyberryMetrics.gutter,
            12,
            LyberryMetrics.gutter,
            28,
          ),
          children: <Widget>[
            const SectionLabel(label: 'File'),
            const SizedBox(height: 8),
            Text(
              preview.fileName,
              key: const Key('merge-file-name'),
              style: const TextStyle(fontSize: 15, color: LyberryColors.ink),
            ),
            const SizedBox(height: 4),
            Text(
              '${megabytes.toStringAsFixed(1)} MiB | '
              '${preview.snapshot.items.length} copies | '
              '${preview.snapshot.assets.length} images',
              style: LyberryType.bodyMuted,
            ),
            const SizedBox(height: 20),
            const SectionLabel(label: 'What will change'),
            const SizedBox(height: 8),
            _row('New copies added', '${preview.added}'),
            _row('Existing copies replaced', '${preview.updated}'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: LyberryColors.surface,
                border: Border.all(color: LyberryColors.rule),
                borderRadius: BorderRadius.circular(LyberryMetrics.corner),
              ),
              child: Text(
                'Replaced copies take every field from this file, including '
                'rating, review, notes and photos. Copies that are not in the '
                'file stay untouched. Nothing has changed yet.',
                style: LyberryType.body,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('merge-confirm'),
              onPressed: _busy ? null : _apply,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Merge into library'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('merge-cancel'),
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: LyberryType.body)),
          Text(value, style: LyberryType.display(size: 16, weight: 600)),
        ],
      ),
    );
  }

  Future<void> _apply() async {
    setState(() => _busy = true);
    final services = AppServicesScope.of(context);
    final controller = LibraryScope.of(context);
    final navigator = Navigator.of(context);
    try {
      final MergeResult result = await services.backup.apply(
        widget.preview.snapshot,
      );
      await controller.refresh();
      if (!mounted) return;
      navigator.pop(result);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, describeFailure(error));
    }
  }
}
