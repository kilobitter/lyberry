import 'package:flutter/material.dart';
import 'package:lyberry/domain/media_asset.dart';
import 'package:lyberry/domain/media_item.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/decoded_image_size.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/library_scope.dart';
import 'package:lyberry/ui/navigation.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/masthead.dart';
import 'package:lyberry/ui/widgets/media_cover.dart';
import 'package:lyberry/ui/widgets/star_rating.dart';

/// Everything about one owned copy, including its private fields.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.itemId});

  final String itemId;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  MediaItem? _item;
  String? _error;
  bool _loading = true;
  bool _requested = false;
  bool _loadingAction = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    _load();
  }

  Future<void> _load() async {
    final controller = LibraryScope.of(context);
    try {
      final item = await controller.item(widget.itemId);
      if (!mounted) return;
      setState(() {
        _item = item;
        _loading = false;
        _error = item == null
            ? 'This copy is no longer in your library.'
            : null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeFailure(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          item?.title ?? 'Copy',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          if (item != null)
            IconButton(
              key: const Key('detail-edit'),
              tooltip: 'Edit copy',
              onPressed: () async {
                await openEditor(context, existing: item);
                if (mounted) await _load();
              },
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: item == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  LyberryMetrics.gutter,
                  8,
                  LyberryMetrics.gutter,
                  12,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('detail-add-copy'),
                        onPressed: _loadingAction ? null : () => _addCopy(item),
                        child: const Text('Add another copy'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      key: const Key('detail-delete'),
                      tooltip: 'Delete copy',
                      onPressed: _loadingAction ? null : _confirmDelete,
                      color: LyberryColors.signal,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final item = _item;
    if (item == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(LyberryMetrics.gutter),
          child: Text(
            _error ?? 'This copy is unavailable.',
            key: const Key('detail-error'),
            textAlign: TextAlign.center,
            style: LyberryType.bodyMuted,
          ),
        ),
      );
    }
    final coverId = item.coverAssetId;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        LyberryMetrics.gutter,
        8,
        LyberryMetrics.gutter,
        24,
      ),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260, maxHeight: 260),
            child: AspectRatio(
              aspectRatio: 1,
              child: MediaCover(
                medium: item.medium,
                image: coverId == null
                    ? null
                    : LibraryScope.of(context).asset(coverId),
                cacheWidth: decodedImageWidth(context, 260),
                semanticLabel: '${item.title} cover',
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(item.title, style: LyberryType.display(size: 22, weight: 700)),
        const SizedBox(height: 4),
        Text(item.byline, style: LyberryType.bodyMuted),
        const SizedBox(height: 10),
        StarRating(rating: item.rating, iconSize: 18),
        if (item.medium.isFinishable) ...<Widget>[
          const SizedBox(height: 12),
          Semantics(
            key: const Key('detail-finished'),
            container: true,
            label: item.isFinished ? 'Finished' : 'Not finished',
            child: ExcludeSemantics(
              child: Row(
                children: <Widget>[
                  Icon(
                    item.isFinished
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: item.isFinished
                        ? LyberryColors.signal
                        : LyberryColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    item.isFinished ? 'Finished' : 'Not finished',
                    style: LyberryType.body,
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 22),
        SectionLabel(label: 'Review'),
        const SizedBox(height: 6),
        _paragraph(item.review, empty: 'No review written yet.'),
        const SizedBox(height: 18),
        SectionLabel(label: 'Notes'),
        const SizedBox(height: 6),
        _paragraph(item.notes, empty: 'No private notes yet.'),
        const SizedBox(height: 18),
        SectionLabel(
          label: 'Photos',
          trailing: item.photoAssetIds.isEmpty
              ? null
              : '${item.photoAssetIds.length}',
        ),
        const SizedBox(height: 8),
        _photoStrip(item),
        const SizedBox(height: 20),
        SectionLabel(label: 'Details'),
        const SizedBox(height: 8),
        _detailRow('Medium', item.medium.label),
        _detailRow('Creator', item.creator),
        if (item.year != null) _detailRow('Year', '${item.year}'),
        _detailRow('Publisher', item.publisher),
        if (item.barcode != null) _detailRow('Barcode', item.barcode!),
        if (item.platform.isNotEmpty) _detailRow('Platform', item.platform),
        if (item.description.isNotEmpty)
          _detailRow('Description', item.description),
        _detailRow('Added', _formatTimestamp(item.createdAt)),
        _detailRow('Updated', _formatTimestamp(item.updatedAt)),
      ],
    );
  }

  Widget _paragraph(String text, {required String empty}) {
    if (text.trim().isEmpty) {
      return Text(empty, style: LyberryType.bodyMuted);
    }
    return Text(text, style: LyberryType.body);
  }

  Widget _detailRow(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(label.toUpperCase(), style: LyberryType.eyebrow()),
          ),
          Expanded(child: Text(value, style: LyberryType.body)),
        ],
      ),
    );
  }

  Widget _photoStrip(MediaItem item) {
    if (item.photoAssetIds.isEmpty) {
      return Text('No photos yet.', style: LyberryType.bodyMuted);
    }
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: item.photoAssetIds.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final id = item.photoAssetIds[index];
          return InkWell(
            key: Key('detail-photo-$index'),
            onTap: () => _viewPhoto(id),
            child: SizedBox(
              width: 92,
              height: 92,
              child: FutureBuilder<MediaAsset?>(
                future: LibraryScope.of(context).asset(id),
                builder: (context, snapshot) {
                  final bytes = snapshot.data?.bytes;
                  if (bytes == null) {
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: LyberryColors.surface,
                        border: Border.all(color: LyberryColors.rule),
                        borderRadius: BorderRadius.circular(
                          LyberryMetrics.corner,
                        ),
                      ),
                    );
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(LyberryMetrics.corner),
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      cacheWidth: decodedImageWidth(context, 92),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _viewPhoto(String id) async {
    final MediaAsset? asset;
    try {
      asset = await LibraryScope.of(context).asset(id);
    } on Object catch (error) {
      if (mounted) showMessage(context, describeFailure(error));
      return;
    }
    if (!mounted) return;
    if (asset == null) return;
    final imageBytes = asset.bytes;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: InteractiveViewer(
                child: Image.memory(imageBytes, fit: BoxFit.contain),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addCopy(MediaItem item) async {
    setState(() => _loadingAction = true);
    final controller = LibraryScope.of(context);
    try {
      final copy = await controller.addCopy(item.id);
      if (!mounted) return;
      setState(() => _loadingAction = false);
      showMessage(
        context,
        'Added another copy. Rating, review, notes, finished and photos start '
        'empty.',
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => openDetail(context, copy.id),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _loadingAction = false);
      showMessage(context, describeFailure(error));
    }
  }

  Future<void> _confirmDelete() async {
    final item = _item;
    if (item == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this copy?'),
        content: Text(
          '"${item.title}" and its personal details will be removed from this '
          'device.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('detail-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('detail-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final controller = LibraryScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _loadingAction = true);
    try {
      await controller.deleteItem(item.id);
      if (!mounted) {
        // The user left this screen while the delete was in flight.
        if (messenger.mounted) {
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Copy deleted.')));
        }
        return;
      }
      navigator.pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Copy deleted.')));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _loadingAction = false);
      showMessage(context, describeFailure(error));
    }
  }
}

String _formatTimestamp(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = parsed.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
