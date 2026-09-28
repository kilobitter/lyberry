import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/services/movies/movie_catalog.dart';
import 'package:lyberry/state/movie_search_controller.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/navigation.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/masthead.dart';
import 'package:lyberry/ui/widgets/state_views.dart';

/// Explicit UPCMDB title search for a scanned DVD/Blu-ray barcode.
///
/// Nothing is requested until the user submits, and the scanned code travels
/// back with the chosen candidate so the editor still stores the code that was
/// actually scanned.
class MovieSearchScreen extends StatefulWidget {
  const MovieSearchScreen({
    super.key,
    required this.identifier,
    this.mediumHint,
    this.controller,
    this.catalog,
  });

  final NormalizedIdentifier identifier;
  final MediaType? mediumHint;

  /// Injected by tests; the real screen uses the app services.
  final MovieSearchController? controller;
  final MovieCatalog? catalog;

  @override
  State<MovieSearchScreen> createState() => _MovieSearchScreenState();
}

class _MovieSearchScreenState extends State<MovieSearchScreen> {
  late final MovieSearchController _controller;
  late final bool _ownsController;
  late final MovieCatalog _catalog;
  final TextEditingController _title = TextEditingController();
  final TextEditingController _year = TextEditingController();
  bool _started = false;
  bool _configured = true;
  String? _configuredError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final services = AppServicesScope.of(context);
    final catalog = widget.catalog ?? services.movies;
    _catalog = catalog;
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        MovieSearchController(catalog: catalog, clock: services.clock);
    _refreshConfigured(catalog);
  }

  Future<void> _refreshConfigured(MovieCatalog catalog) async {
    // Reading the credential state performs no network request.
    var configured = true;
    String? error;
    try {
      configured = await catalog.isConfigured;
    } on ProviderException catch (failure) {
      configured = false;
      // A keystore read failure is not a missing key: report it accurately.
      error = failure.message;
    } on Object {
      configured = false;
      error = 'The UPCMDB key could not be read on this device.';
    }
    if (!mounted) return;
    setState(() {
      _configured = configured;
      _configuredError = configured ? null : error;
    });
  }

  /// Opens Settings and re-reads the credential state on return, so saving or
  /// removing the key takes effect without leaving this screen.
  Future<void> _openSettings() async {
    final catalog = _catalog;
    await openSettings(context);
    if (!mounted) return;
    await _refreshConfigured(catalog);
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search movies')),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(
            LyberryMetrics.gutter,
            12,
            LyberryMetrics.gutter,
            28,
          ),
          children: <Widget>[
            Text(
              widget.identifier.value,
              key: const Key('movie-search-code'),
              style: LyberryType.display(size: 22, weight: 700),
            ),
            const SizedBox(height: 4),
            Text(
              'The scanned code is kept with whatever you pick.',
              style: LyberryType.bodyMuted,
            ),
            const SizedBox(height: 16),
            if (!_configured) _keyBanner(),
            TextField(
              key: const Key('movie-search-field'),
              controller: _title,
              enabled: !_controller.isRunning,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              maxLength: 200,
              onChanged: _controller.setTitle,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                hintText: 'Movie title',
                helperText:
                    'Search sends only this title and year to UPCMDB. Nothing '
                    'from your collection is sent.',
                helperMaxLines: 4,
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('movie-search-year'),
              controller: _year,
              enabled: !_controller.isRunning,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.search,
              maxLength: 4,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              onChanged: _controller.setYear,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Year (optional)',
                helperText:
                    'Optional four-digit release year, for example 1999.',
                helperMaxLines: 2,
                counterText: '',
                errorText: _controller.yearProblem,
              ),
            ),
            const SizedBox(height: 12),
            // The button's enabled state follows the fields themselves, so
            // typing alone never triggers a request.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _title,
              builder: (context, value, _) {
                if (_controller.isRunning) {
                  return Row(
                    children: <Widget>[
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Searching UPCMDB...',
                          key: const Key('movie-search-running'),
                          style: LyberryType.bodyMuted,
                        ),
                      ),
                    ],
                  );
                }
                return FilledButton.icon(
                  key: const Key('movie-search-submit'),
                  onPressed: _controller.canSubmit ? _submit : null,
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('Search by title'),
                );
              },
            ),
            const SizedBox(height: 14),
            ..._content(),
            const SizedBox(height: 18),
            TextButton(
              key: const Key('movie-search-manual'),
              onPressed: () =>
                  Navigator.of(context).pop<LookupChoice>(const AddManually()),
              child: const Text('Add it by hand instead'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _keyBanner() {
    final error = _configuredError;
    return Container(
      key: const Key('movie-search-missing-key'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LyberryColors.surface,
        border: Border.all(color: LyberryColors.signal),
        borderRadius: BorderRadius.circular(LyberryMetrics.corner),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            error == null ? 'KEYS NEEDED' : 'CREDENTIALS UNAVAILABLE',
            style: LyberryType.eyebrow(),
          ),
          const SizedBox(height: 6),
          Text(
            error ??
                'Add your UPCMDB API key in Settings to search movies by title. '
                    'The scanned code stays on this screen.',
            key: const Key('movie-search-key-message'),
            style: LyberryType.bodyMuted,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('movie-search-open-settings'),
            onPressed: _openSettings,
            icon: const Icon(Icons.key_outlined, size: 18),
            label: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  List<Widget> _content() {
    switch (_controller.status) {
      case MovieSearchStatus.idle:
        return <Widget>[
          Text(
            'Type the title printed on the case.',
            key: const Key('movie-search-idle'),
            style: LyberryType.bodyMuted,
          ),
        ];
      case MovieSearchStatus.running:
        return const <Widget>[];
      case MovieSearchStatus.ready:
        return <Widget>[
          SectionLabel(
            label: 'Results',
            trailing: '${_controller.candidates.length}',
          ),
          const SizedBox(height: 10),
          for (final candidate in _controller.candidates)
            _MovieResultCard(
              candidate: candidate,
              onUse: () => Navigator.of(
                context,
              ).pop<LookupChoice>(UseCandidate(candidate)),
            ),
        ];
      case MovieSearchStatus.empty:
      case MovieSearchStatus.failed:
        return <Widget>[
          MessageView(
            key: const Key('movie-search-empty'),
            icon: Icons.movie_filter_outlined,
            iconColor: _controller.status == MovieSearchStatus.failed
                ? LyberryColors.signal
                : LyberryColors.muted,
            title: 'No movie found',
            body:
                '${_controller.errorMessage ?? 'UPCMDB had no match for that title.'}\n'
                'Try a different title, or add the copy by hand.',
            primaryAction: FilledButton.icon(
              key: const Key('movie-search-retry'),
              onPressed: _controller.canSubmit ? _submit : null,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ),
        ];
    }
  }

  Future<void> _submit() async {
    final error = _configuredError;
    if (error != null) {
      showMessage(context, error);
      return;
    }
    if (!_configured) {
      showMessage(context, 'Add your UPCMDB API key in Settings first.');
      return;
    }
    _controller
      ..setTitle(_title.text)
      ..setYear(_year.text);
    await _controller.submit();
  }
}

class _MovieResultCard extends StatelessWidget {
  const _MovieResultCard({required this.candidate, required this.onUse});

  final MetadataCandidate candidate;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final format = candidate.format.trim();
    // The edition text is what tells two releases of one film apart, so it
    // stays visible in the result card.
    final edition = candidate.edition.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
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
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  candidate.providerLabel.toUpperCase(),
                  style: LyberryType.eyebrow(color: LyberryColors.muted),
                ),
                Text(
                  candidate.matchKind.label.toUpperCase(),
                  style: LyberryType.eyebrow(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              candidate.title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: LyberryColors.ink,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              <String>[
                if (format.isNotEmpty) format,
                if (edition.isNotEmpty) edition,
                if (candidate.year != null) '${candidate.year}',
                if (candidate.creator.isNotEmpty) candidate.creator,
              ].join(' | '),
              key: Key('movie-result-format-${candidate.externalId}'),
              style: LyberryType.bodyMuted,
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: Key('movie-result-use-${candidate.externalId}'),
              onPressed: onUse,
              child: const Text('Use this'),
            ),
          ],
        ),
      ),
    );
  }
}
