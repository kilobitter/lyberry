import 'package:flutter/material.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/state/lookup_controller.dart';
import 'package:lyberry/state/web_lookup_controller.dart';
import 'package:lyberry/ui/navigation.dart';
import 'package:lyberry/ui/screens/game_search_screen.dart';
import 'package:lyberry/ui/screens/movie_search_screen.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/media_cover.dart';
import 'package:lyberry/ui/widgets/state_views.dart';
import 'package:lyberry/domain/media_type.dart';

/// What the candidate screen gives back to its caller.
sealed class LookupChoice {
  const LookupChoice();
}

/// The user picked a provider result.
class UseCandidate extends LookupChoice {
  const UseCandidate(this.candidate);

  final MetadataCandidate candidate;
}

/// The user wants to type the copy in by hand instead.
class AddManually extends LookupChoice {
  const AddManually();
}

/// Provider candidates for one identifier. Nothing is saved here: the user
/// always chooses, and the chosen values stay editable in the editor.
class CandidatesScreen extends StatefulWidget {
  const CandidatesScreen({super.key, required this.query, this.controller});

  final LookupQuery query;

  /// Injected by tests; the real screen builds its own controller.
  final LookupController? controller;

  @override
  State<CandidatesScreen> createState() => _CandidatesScreenState();
}

class _CandidatesScreenState extends State<CandidatesScreen> {
  late final LookupController _controller;
  late final bool _ownsController;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        LookupController(service: AppServicesScope.of(context).metadata);
    if (_controller.status == LookupStatus.idle) {
      _controller.search(widget.query);
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Matches')),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        LyberryMetrics.gutter,
        12,
        LyberryMetrics.gutter,
        28,
      ),
      children: <Widget>[
        Text(
          widget.query.identifier.value,
          key: const Key('candidates-code'),
          style: LyberryType.display(size: 22, weight: 700),
        ),
        const SizedBox(height: 4),
        Text(
          '${widget.query.identifier.kind.label} | '
          '${_controller.candidates.isEmpty ? 'asking providers' : '${_controller.candidates.length} result(s)'}'
          '${_controller.fromCache ? ' | cached' : ''}',
          style: LyberryType.bodyMuted,
        ),
        const SizedBox(height: 10),
        Text(
          'Nothing is saved until you pick a match and save the copy.',
          style: LyberryType.bodyMuted,
        ),
        const SizedBox(height: 18),
        ..._content(context),
      ],
    );
  }

  List<Widget> _content(BuildContext context) {
    switch (_controller.status) {
      case LookupStatus.idle:
      case LookupStatus.loading:
        return <Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          Text(
            'Asking ${_providerNames()}',
            textAlign: TextAlign.center,
            style: LyberryType.bodyMuted,
          ),
        ];
      case LookupStatus.ready:
        return <Widget>[
          if (_controller.failures.isNotEmpty) _failureBanner(),
          for (final candidate in _controller.candidates)
            _CandidateCard(
              candidate: candidate,
              onTap: () => Navigator.of(context).pop(UseCandidate(candidate)),
            ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('candidates-manual'),
            onPressed: () =>
                Navigator.of(context).pop<LookupChoice>(const AddManually()),
            child: const Text('None of these | add it by hand'),
          ),
          // Available even when results exist, so unwanted matches are not a
          // dead end for a game.
          _gameSearchAction(padded: true),
          _movieSearchAction(padded: true),
        ];
      case LookupStatus.empty:
        return <Widget>[
          MessageView(
            key: const Key('candidates-empty'),
            icon: Icons.search_off,
            title: 'No matches',
            body:
                'No provider had a record for ${widget.query.identifier.value}. '
                'You can search the open web, paste a product link, or add the '
                'copy by hand.',
            primaryAction: FilledButton(
              key: const Key('candidates-empty-manual'),
              onPressed: () =>
                  Navigator.of(context).pop<LookupChoice>(const AddManually()),
              child: const Text('Add it by hand'),
            ),
            secondaryAction: Column(
              children: <Widget>[
                _webActions(),
                _gameSearchAction(padded: true),
                _movieSearchAction(padded: true),
              ],
            ),
          ),
          if (_controller.failures.isNotEmpty) _failureBanner(),
        ];
      case LookupStatus.failed:
        return <Widget>[
          MessageView(
            key: const Key('candidates-error'),
            icon: Icons.cloud_off,
            iconColor: LyberryColors.signal,
            title: 'Lookup failed',
            body:
                '${_controller.errorMessage ?? 'The providers could not be reached.'}\n'
                'Your code can still be added by hand, offline.',
            primaryAction: FilledButton.icon(
              key: const Key('candidates-retry'),
              onPressed: _controller.retry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
            secondaryAction: TextButton(
              key: const Key('candidates-error-manual'),
              onPressed: () =>
                  Navigator.of(context).pop<LookupChoice>(const AddManually()),
              child: const Text('Add it by hand'),
            ),
          ),
          _webActions(padded: true),
          _gameSearchAction(padded: true),
          _movieSearchAction(padded: true),
          if (_controller.failures.isNotEmpty) _failureBanner(),
        ];
    }
  }

  /// Search the web / import a link, offered wherever the free path came up
  /// empty or failed. Both stay explicit actions with their own screen.
  Widget _webActions({bool padded = false}) {
    return Padding(
      padding: EdgeInsets.only(top: padded ? 4 : 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton.icon(
            key: const Key('candidates-web-search'),
            onPressed: () => _openWeb(),
            icon: const Icon(Icons.travel_explore, size: 18),
            label: const Text('Search the web'),
          ),
          OutlinedButton.icon(
            key: const Key('candidates-web-link'),
            onPressed: () => _openWeb(mode: WebLookupMode.link),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Import from link'),
          ),
        ],
      ),
    );
  }

  Future<void> _openWeb({WebLookupMode mode = WebLookupMode.search}) async {
    final choice = await openWebLookup(
      context,
      identifier: widget.query.identifier,
      mediumHint: widget.query.mediumHint,
      mode: mode,
    );
    if (!mounted || choice == null) return;
    Navigator.of(context).pop<LookupChoice>(choice);
  }

  /// A title search only makes sense for a game or an unknown code; a book,
  /// disc or film hint keeps its own path.
  bool get _gameSearchAvailable =>
      widget.query.mediumHint == MediaType.game ||
      widget.query.mediumHint == null;

  Widget _gameSearchAction({bool padded = false}) {
    if (!_gameSearchAvailable) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: padded ? 4 : 0),
      child: OutlinedButton.icon(
        key: const Key('candidates-game-title-search'),
        onPressed: _openGameSearch,
        icon: const Icon(Icons.videogame_asset, size: 18),
        label: const Text('Search games by title'),
      ),
    );
  }

  Future<void> _openGameSearch() async {
    final choice = await Navigator.of(context).push<LookupChoice>(
      MaterialPageRoute<LookupChoice>(
        builder: (_) => GameSearchScreen(
          identifier: widget.query.identifier,
          mediumHint: widget.query.mediumHint,
        ),
      ),
    );
    if (!mounted || choice == null) return;
    Navigator.of(context).pop<LookupChoice>(choice);
  }

  /// A title search only makes sense for a DVD/Blu-ray or an unknown code; a
  /// book, music or game hint keeps its own path, and an ISBN is never a movie.
  bool get _movieSearchAvailable =>
      !widget.query.identifier.isIsbn &&
      (widget.query.mediumHint == MediaType.dvd ||
          widget.query.mediumHint == MediaType.bluray ||
          widget.query.mediumHint == null);

  Widget _movieSearchAction({bool padded = false}) {
    if (!_movieSearchAvailable) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: padded ? 4 : 0),
      child: OutlinedButton.icon(
        key: const Key('candidates-movie-title-search'),
        onPressed: _openMovieSearch,
        icon: const Icon(Icons.movie_outlined, size: 18),
        label: const Text('Search movies by title'),
      ),
    );
  }

  Future<void> _openMovieSearch() async {
    final choice = await Navigator.of(context).push<LookupChoice>(
      MaterialPageRoute<LookupChoice>(
        builder: (_) => MovieSearchScreen(
          identifier: widget.query.identifier,
          mediumHint: widget.query.mediumHint,
        ),
      ),
    );
    if (!mounted || choice == null) return;
    Navigator.of(context).pop<LookupChoice>(choice);
  }

  Widget _failureBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LyberryColors.surface,
        border: Border.all(color: LyberryColors.rule),
        borderRadius: BorderRadius.circular(LyberryMetrics.corner),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('PARTIAL RESULTS', style: LyberryType.eyebrow()),
          const SizedBox(height: 6),
          for (final failure in _controller.failures)
            Text(
              '${failure.providerLabel}: ${failure.kind.label}. ${failure.message}',
              style: LyberryType.bodyMuted,
            ),
        ],
      ),
    );
  }

  String _providerNames() {
    final names = AppServicesScope.of(context).metadata.providers
        .where((provider) => provider.supports(widget.query.mediumHint))
        .map((provider) => provider.label)
        .toList(growable: false);
    return names.isEmpty ? 'metadata providers' : names.join(', ');
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.candidate, required this.onTap});

  final MetadataCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final medium = candidate.medium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: 'Use ${candidate.title} from ${candidate.providerLabel}',
        child: InkWell(
          key: Key('candidate-${candidate.key}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(LyberryMetrics.corner),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: LyberryColors.surface,
              border: Border.all(color: LyberryColors.rule),
              borderRadius: BorderRadius.circular(LyberryMetrics.corner),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: medium == null
                          ? const Icon(
                              Icons.image_outlined,
                              color: LyberryColors.muted,
                            )
                          : CoverPlaceholder(medium: medium),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            candidate.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: LyberryColors.ink,
                            ),
                          ),
                          if (candidate.subtitle.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 3),
                            Text(
                              candidate.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: LyberryType.bodyMuted,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        candidate.matchKind.label.toUpperCase(),
                        style: LyberryType.eyebrow(
                          color: candidate.matchKind == MatchKind.exact
                              ? LyberryColors.signal
                              : LyberryColors.muted,
                        ),
                      ),
                    ),
                    Text(candidate.providerLabel, style: LyberryType.bodyMuted),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
