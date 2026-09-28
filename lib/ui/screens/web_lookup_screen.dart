import 'package:flutter/material.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/state/web_lookup_controller.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/navigation.dart';
import 'package:lyberry/ui/screens/candidates_screen.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/masthead.dart';
import 'package:lyberry/ui/widgets/state_views.dart';
import 'package:url_launcher/url_launcher.dart';

/// Explicit web lookup: search provider pages or import one pasted link.
///
/// The screen never starts work by itself. A lookup only happens when the user
/// taps the action, and every result stays a suggestion until the user picks it.
class WebLookupScreen extends StatefulWidget {
  const WebLookupScreen({
    super.key,
    required this.identifier,
    this.mediumHint,
    this.initialMode = WebLookupMode.search,
    this.controller,
  });

  final NormalizedIdentifier identifier;
  final MediaType? mediumHint;
  final WebLookupMode initialMode;

  /// Injected by tests; the real screen builds its own controller.
  final WebLookupController? controller;

  @override
  State<WebLookupScreen> createState() => _WebLookupScreenState();
}

class _WebLookupScreenState extends State<WebLookupScreen> {
  late final WebLookupController _controller;
  late final bool _ownsController;
  final TextEditingController _url = TextEditingController();
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        WebLookupController(
          service: AppServicesScope.of(context).webLookup,
          identifier: widget.identifier,
          mediumHint: widget.mediumHint,
          mode: widget.initialMode,
        );
  }

  @override
  void dispose() {
    _url.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Web lookup')),
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
              key: const Key('web-code'),
              style: LyberryType.display(size: 22, weight: 700),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.identifier.kind.label} | nothing is saved until you '
              'pick a result and save the copy.',
              style: LyberryType.bodyMuted,
            ),
            const SizedBox(height: 16),
            _mediumRow(),
            const SizedBox(height: 16),
            _modeRow(),
            const SizedBox(height: 12),
            if (_controller.mode == WebLookupMode.link) ...<Widget>[
              TextField(
                key: const Key('web-link-field'),
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.go,
                onChanged: _controller.setUrlText,
                decoration: const InputDecoration(
                  hintText: 'https://shop.example/product',
                  helperText:
                      'A public https product page. Pages behind a login or '
                      'CAPTCHA cannot be read.',
                  helperMaxLines: 4,
                ),
                onSubmitted: (_) => _readLink(),
              ),
              const SizedBox(height: 12),
            ],
            _actionRow(),
            const SizedBox(height: 14),
            if (_controller.missingKey case final failure?) _keyBanner(failure),
            ..._content(context),
            const SizedBox(height: 18),
            const SectionLabel(label: 'What gets sent'),
            const SizedBox(height: 6),
            Text(
              'A web search sends the code (and the medium hint you choose) to '
              'Tavily. Extraction sends the code plus public page excerpts to '
              'DeepSeek. Page text is treated as untrusted data. Your notes, '
              'reviews, photos and the rest of the library are never sent.',
              key: const Key('web-privacy-note'),
              style: LyberryType.bodyMuted,
            ),
            const SizedBox(height: 6),
            Text(
              'Web search and extraction are paid third-party services billed '
              'to your own API keys. Nothing runs in the background.',
              style: LyberryType.bodyMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediumRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SectionLabel(label: 'Medium hint'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _mediumChip(null, 'Any'),
            for (final type in MediaType.values) _mediumChip(type, type.label),
          ],
        ),
      ],
    );
  }

  Widget _mediumChip(MediaType? type, String label) {
    final selected = _controller.mediumHint == type;
    final key = type == null
        ? 'web-medium-any'
        : 'web-medium-${type.wireValue}';
    return OutlinedButton(
      key: Key(key),
      onPressed: () => _controller.setMediumHint(type),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? LyberryColors.ink : LyberryColors.muted,
        backgroundColor: selected ? LyberryColors.signal : null,
        side: BorderSide(
          color: selected ? LyberryColors.signal : LyberryColors.rule,
        ),
        minimumSize: const Size(LyberryMetrics.touchTarget, 40),
      ),
      child: Text(label, maxLines: 1),
    );
  }

  Widget _modeRow() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final mode in WebLookupMode.values)
          OutlinedButton(
            key: Key('web-mode-${mode.name}'),
            onPressed: _controller.isRunning
                ? null
                : () => _controller.setMode(mode),
            style: OutlinedButton.styleFrom(
              foregroundColor: _controller.mode == mode
                  ? LyberryColors.ink
                  : LyberryColors.muted,
              backgroundColor: _controller.mode == mode
                  ? LyberryColors.surfaceHigh
                  : null,
              side: BorderSide(
                color: _controller.mode == mode
                    ? LyberryColors.signal
                    : LyberryColors.rule,
              ),
            ),
            child: Text(mode.label),
          ),
      ],
    );
  }

  Widget _actionRow() {
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
              _controller.mode == WebLookupMode.search
                  ? 'Searching for ${widget.identifier.value}...'
                  : 'Reading the page...',
              key: const Key('web-running'),
              style: LyberryType.bodyMuted,
            ),
          ),
          OutlinedButton(
            key: const Key('web-cancel'),
            onPressed: _controller.cancel,
            child: const Text('Cancel'),
          ),
        ],
      );
    }
    final isLink = _controller.mode == WebLookupMode.link;
    return FilledButton.icon(
      key: Key(isLink ? 'web-read' : 'web-search'),
      onPressed: isLink ? _readLink : _search,
      icon: Icon(isLink ? Icons.link : Icons.travel_explore, size: 18),
      label: Text(
        isLink ? 'Read page' : 'Search the web for this code',
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _keyBanner(WebLookupFailure failure) {
    return Container(
      key: const Key('web-missing-key'),
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
          Text('KEY NEEDED', style: LyberryType.eyebrow()),
          const SizedBox(height: 6),
          Text(failure.message, style: LyberryType.bodyMuted),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('web-open-settings'),
            onPressed: () => openSettings(context),
            icon: const Icon(Icons.key_outlined, size: 18),
            label: const Text('Open Settings'),
          ),
          const SizedBox(height: 6),
          Text(
            'Your code stays on this screen; a new tap is needed after you '
            'save a key.',
            style: LyberryType.bodyMuted,
          ),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    switch (_controller.status) {
      case WebLookupStatus.idle:
        return <Widget>[
          Text(
            _controller.mode.hint,
            key: const Key('web-idle'),
            style: LyberryType.bodyMuted,
          ),
        ];
      case WebLookupStatus.running:
        return const <Widget>[];
      case WebLookupStatus.ready:
        return <Widget>[
          SectionLabel(
            label: 'Results',
            trailing: '${_controller.candidates.length}',
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < _controller.candidates.length; index++)
            _WebCandidateCard(
              candidate: _controller.candidates[index],
              // Occurrence-unique keys: two candidates can legitimately share
              // one provider identity (two products on the same page), so the
              // position in the list is what makes the key unique.
              index: index,
              onUse: () => _use(_controller.candidates[index]),
            ),
          if (_controller.failures.isNotEmpty) _failureBox(),
          const SizedBox(height: 8),
          _manualButton(),
        ];
      case WebLookupStatus.empty:
      case WebLookupStatus.failed:
        return <Widget>[
          MessageView(
            key: const Key('web-empty'),
            icon: _controller.status == WebLookupStatus.failed
                ? Icons.cloud_off
                : Icons.travel_explore,
            iconColor: _controller.status == WebLookupStatus.failed
                ? LyberryColors.signal
                : LyberryColors.muted,
            title: _controller.status == WebLookupStatus.failed
                ? 'Web lookup did not finish'
                : 'No web result',
            body:
                '${_controller.errorMessage ?? 'Nothing usable came back.'}\n'
                'You can add the copy by hand, or paste the product link.',
            primaryAction: _manualButton(),
            secondaryAction: OutlinedButton(
              key: const Key('web-empty-retry'),
              onPressed: _controller.mode == WebLookupMode.link
                  ? _readLink
                  : _search,
              child: Text(
                _controller.mode == WebLookupMode.link
                    ? 'Try the link again'
                    : 'Search again',
              ),
            ),
          ),
          if (_controller.failures.isNotEmpty) _failureBox(),
        ];
    }
  }

  Widget _manualButton() => TextButton(
    key: const Key('web-manual'),
    onPressed: () =>
        Navigator.of(context).pop<LookupChoice>(const AddManually()),
    child: const Text('Add it by hand instead'),
  );

  Widget _failureBox() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LyberryColors.surface,
        border: Border.all(color: LyberryColors.rule),
        borderRadius: BorderRadius.circular(LyberryMetrics.corner),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('RETRIEVAL LOG', style: LyberryType.eyebrow()),
          const SizedBox(height: 6),
          for (final failure in _controller.failures)
            Text(
              '${failure.stage.label} | ${failure.label}: '
              '${failure.kind.label}. ${failure.message}',
              // No key on purpose: this is a stateless row, and two failures of
              // the same kind - or two failures from the same host - must both
              // render without colliding in the Column.
              style: LyberryType.bodyMuted,
            ),
          if (_controller.pages.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Page text retrieved from: '
              '${_controller.pages.map((page) => page.domain).join(', ')}',
              style: LyberryType.bodyMuted,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _search() => _controller.runSearch();

  Future<void> _readLink() => _controller.runLink();

  Future<void> _use(WebCandidate candidate) async {
    var chosen = candidate;
    if (candidate.candidate.medium == null) {
      final medium = await _askMedium(candidate.candidate.title);
      if (medium == null) return; // The user backed out; nothing is picked.
      chosen = WebCandidate(
        candidate: _withMedium(candidate.candidate, medium),
        origin: candidate.origin,
        sourceUrl: candidate.sourceUrl,
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop<LookupChoice>(UseCandidate(chosen.candidate));
  }

  static MetadataCandidate _withMedium(
    MetadataCandidate candidate,
    MediaType medium,
  ) => MetadataCandidate(
    providerId: candidate.providerId,
    providerLabel: candidate.providerLabel,
    externalId: candidate.externalId,
    matchKind: candidate.matchKind,
    title: candidate.title,
    medium: medium,
    creator: candidate.creator,
    year: candidate.year,
    publisher: candidate.publisher,
    description: candidate.description,
    platform: candidate.platform,
    coverUrl: candidate.coverUrl,
    sourceUrl: candidate.sourceUrl,
  );

  /// Asks for the medium instead of silently defaulting a film to a book.
  Future<MediaType?> _askMedium(String title) async {
    return showDialog<MediaType>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('web-medium-dialog'),
        title: const Text('Which medium is this?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '$title is a physical copy. Pick the shelf it belongs on.',
                style: LyberryType.bodyMuted,
              ),
              const SizedBox(height: 12),
              for (final type in MediaType.values)
                TextButton(
                  key: Key('web-choose-${type.wireValue}'),
                  onPressed: () => Navigator.of(dialogContext).pop(type),
                  child: Text(type.label),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('web-medium-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }
}

class _WebCandidateCard extends StatelessWidget {
  const _WebCandidateCard({
    required this.candidate,
    required this.index,
    required this.onUse,
  });

  final WebCandidate candidate;
  final int index;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final value = candidate.candidate;
    final source = candidate.sourceUrl;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: 'Use ${value.title} from ${candidate.origin.label}',
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
              // Badges and actions wrap, so a 320px wide phone at 1.6x text
              // never clips or overflows a result card.
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    candidate.origin.label.toUpperCase(),
                    style: LyberryType.eyebrow(
                      color: candidate.origin == WebCandidateOrigin.structured
                          ? LyberryColors.signal
                          : LyberryColors.muted,
                    ),
                  ),
                  Text(
                    candidate.isExact ? 'EXACT CODE MATCH' : 'POSSIBLE MATCH',
                    style: LyberryType.eyebrow(
                      color: candidate.isExact
                          ? LyberryColors.signal
                          : LyberryColors.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                value.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: LyberryColors.ink,
                ),
              ),
              if (value.subtitle.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                Text(value.subtitle, style: LyberryType.bodyMuted),
              ],
              if (candidate.domain.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  'Source: ${candidate.domain}',
                  style: LyberryType.bodyMuted,
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  FilledButton(
                    key: Key('web-use-$index'),
                    onPressed: onUse,
                    child: const Text('Use this'),
                  ),
                  if (source.isNotEmpty)
                    TextButton.icon(
                      key: Key('web-open-$index'),
                      onPressed: () => _open(source, context),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Open source'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the page in the platform browser, only after this explicit tap.
  static Future<void> _open(String url, BuildContext context) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      showMessage(context, 'That source link cannot be opened.');
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        showMessage(context, 'No app could open that link.');
      }
    } on Object {
      if (context.mounted) {
        showMessage(context, 'That link could not be opened.');
      }
    }
  }
}
