import 'package:flutter/material.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/decoded_image_size.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/library_scope.dart';
import 'package:lyberry/ui/navigation.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/cover_tile.dart';
import 'package:lyberry/ui/widgets/masthead.dart';
import 'package:lyberry/ui/widgets/medium_tabs.dart';
import 'package:lyberry/ui/widgets/state_views.dart';

/// The collection: search, medium filters and the newest-first cover grid.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _noticeCheckScheduled = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = LibraryScope.of(context);
    _scheduleNoticeCheck(controller);
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: LyberryColors.signal,
        backgroundColor: LyberryColors.surface,
        onRefresh: controller.refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                LyberryMetrics.gutter,
                4,
                LyberryMetrics.gutter,
                0,
              ),
              sliver: SliverToBoxAdapter(child: _header(controller)),
            ),
            ..._body(controller),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  /// Lost-data recovery finishes after the first frame, so the notice is pulled
  /// on every controller notification instead of only during the first build.
  void _scheduleNoticeCheck(LibraryController controller) {
    if (_noticeCheckScheduled) return;
    _noticeCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _noticeCheckScheduled = false;
      if (!mounted) return;
      final notice = controller.takeRecoveryNotice();
      if (notice != null) showMessage(context, notice);
    });
  }

  Widget _header(LibraryController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        LyberryMasthead(onAdd: () => openEditor(context)),
        const SizedBox(height: 18),
        Text(
          'Your collection',
          style: LyberryType.display(size: 34, weight: 700),
        ),
        const SizedBox(height: 6),
        Text(
          controller.status == LibraryStatus.ready
              ? _countLabel(controller.totalCount)
              : 'Local library',
          style: const TextStyle(fontSize: 15, color: LyberryColors.muted),
        ),
        const SizedBox(height: 16),
        _searchField(controller),
        const SizedBox(height: 10),
        MediumTabs(
          selected: controller.mediumFilter,
          onSelected: (medium) {
            controller.setMediumFilter(medium);
          },
        ),
        if (controller.mediumFilter == MediaType.game) ...<Widget>[
          const SizedBox(height: 10),
          _platformDropdown(controller),
        ],
        const SizedBox(height: 18),
        SectionLabel(
          label: controller.hasFilters ? 'Results' : 'Recently added',
          trailing: controller.status == LibraryStatus.ready
              ? _countLabel(controller.items.length)
              : null,
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _searchField(LibraryController controller) {
    return TextField(
      key: const Key('home-search'),
      controller: _searchController,
      textInputAction: TextInputAction.search,
      onChanged: controller.setSearch,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        hintText: 'Search your library',
        prefixIcon: const Icon(Icons.search, color: LyberryColors.muted),
        suffixIcon: controller.search.isEmpty
            ? null
            : IconButton(
                key: const Key('home-search-clear'),
                tooltip: 'Clear search',
                icon: const Icon(Icons.close, size: 18),
                color: LyberryColors.muted,
                onPressed: () {
                  _searchController.clear();
                  controller.setSearch('');
                },
              ),
      ),
    );
  }

  /// Platform filter, shown only for games: the one medium with a second
  /// predicate. The control is disabled when no saved game names a platform,
  /// and every option is as wide as the column with an ellipsised label so a
  /// long console name cannot overflow on a narrow, large-text phone.
  Widget _platformDropdown(LibraryController controller) {
    final options = controller.availableGamePlatforms;
    final enabled = options.isNotEmpty;
    final selected = controller.platformFilter;
    // Exact membership: DropdownButton resolves its value with `==`, so a
    // stale or differently-cased string would trip its item assertion.
    final value = selected != null && options.contains(selected)
        ? selected
        : null;
    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Platform'),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          key: const Key('home-platform'),
          value: value,
          isExpanded: true,
          isDense: true,
          hint: const Text('All platforms'),
          onChanged: enabled
              ? (choice) => controller.setPlatformFilter(choice)
              : null,
          items: <DropdownMenuItem<String?>>[
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All platforms'),
            ),
            for (final platform in options)
              DropdownMenuItem<String?>(
                value: platform,
                child: Text(
                  platform,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(LibraryController controller) {
    switch (controller.status) {
      case LibraryStatus.starting:
        return const <Widget>[SliverToBoxAdapter(child: LoadingLibraryView())];
      case LibraryStatus.failed:
        return <Widget>[
          SliverToBoxAdapter(
            child: MessageView(
              key: const Key('home-error'),
              icon: Icons.error_outline,
              iconColor: LyberryColors.signal,
              title: 'Library unavailable',
              body:
                  '${controller.failureMessage ?? 'The library could not be opened.'}\n'
                  'Your file was left untouched.',
              primaryAction: FilledButton.icon(
                key: const Key('home-retry'),
                onPressed: controller.retry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
              ),
            ),
          ),
        ];
      case LibraryStatus.ready:
        if (controller.totalCount == 0) {
          return <Widget>[
            SliverToBoxAdapter(
              child: MessageView(
                key: const Key('home-empty'),
                icon: Icons.library_books_outlined,
                title: 'Nothing here yet',
                body:
                    'Add your first book, CD, DVD, Blu-ray, vinyl or game. '
                    'Everything stays on this device.',
                primaryAction: FilledButton.icon(
                  key: const Key('home-empty-add'),
                  onPressed: () => openEditor(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add a copy'),
                ),
                secondaryAction: TextButton(
                  key: const Key('home-empty-scan'),
                  onPressed: () => openScan(context),
                  child: const Text('Scan a barcode'),
                ),
              ),
            ),
          ];
        }
        if (controller.items.isEmpty) {
          return <Widget>[
            SliverToBoxAdapter(
              child: MessageView(
                key: const Key('home-no-results'),
                icon: Icons.search_off,
                title: 'No matches',
                body: 'Try another title, creator or barcode.',
                primaryAction: OutlinedButton(
                  key: const Key('home-clear-filters'),
                  onPressed: () {
                    _searchController.clear();
                    controller.clearFilters();
                  },
                  child: const Text('Clear filters'),
                ),
              ),
            ),
          ];
        }
        return <Widget>[_grid(controller)];
    }
  }

  Widget _grid(LibraryController controller) {
    final width = MediaQuery.sizeOf(context).width;
    const spacing = 16.0;
    final crossAxisExtent = (width - LyberryMetrics.gutter * 2 - spacing) / 2;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: LyberryMetrics.gutter),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 18,
          mainAxisExtent: CoverTile.extentFor(context, crossAxisExtent),
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = controller.items[index];
          final coverId = item.coverAssetId;
          return CoverTile(
            key: ValueKey<String>(item.id),
            item: item,
            image: coverId == null ? null : controller.asset(coverId),
            cacheWidth: decodedImageWidth(context, crossAxisExtent),
            onTap: () => openDetail(context, item.id),
          );
        }, childCount: controller.items.length),
      ),
    );
  }

  String _countLabel(int count) => count == 1 ? '1 item' : '$count items';
}
