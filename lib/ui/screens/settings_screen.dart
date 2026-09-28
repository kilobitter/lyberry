import 'package:flutter/material.dart';
import 'package:lyberry/app_services.dart';
import 'package:lyberry/domain/library_snapshot.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/backup_service.dart';
import 'package:lyberry/services/keys/api_key_store.dart';
import 'package:lyberry/state/library_controller.dart';
import 'package:lyberry/ui/feedback.dart';
import 'package:lyberry/ui/library_scope.dart';
import 'package:lyberry/ui/screens/merge_preview_screen.dart';
import 'package:lyberry/ui/theme.dart';
import 'package:lyberry/ui/widgets/masthead.dart';
import 'package:url_launcher/url_launcher.dart';

/// Backup, provider and privacy settings.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  String? _status;

  @override
  Widget build(BuildContext context) {
    final controller = LibraryScope.of(context);
    final services = AppServicesScope.of(context);
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          LyberryMetrics.gutter,
          8,
          LyberryMetrics.gutter,
          28,
        ),
        children: <Widget>[
          Text('Settings', style: LyberryType.display(size: 28, weight: 700)),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Library'),
          const SizedBox(height: 8),
          _row('Copies', '${controller.totalCount}'),
          _paragraph(
            'Your collection is stored only on this device. There is no account '
            'and no sync. Images that are no longer attached to a copy are kept '
            'rather than deleted.',
          ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Backup'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const Key('settings-export'),
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Export backup'),
              ),
              OutlinedButton.icon(
                key: const Key('settings-import'),
                onPressed: _busy ? null : _import,
                icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                label: const Text('Import backup'),
              ),
            ],
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _status!,
                key: const Key('settings-backup-status'),
                style: LyberryType.body,
              ),
            ),
          const SizedBox(height: 8),
          _paragraph(
            'A backup is one file with every copy, rating, review, note and '
            'photo. Importing replaces the copies that are in the file and '
            'leaves everything else alone. A backup can be up to 100 MB; each '
            'image is limited to 5 MB and all images together to 60 MB.',
          ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Looking up codes'),
          const SizedBox(height: 8),
          for (final provider in services.metadata.providers)
            _row(provider.label, 'Used for lookups'),
          _paragraph(
            'A lookup needs an internet connection. Each source is a free '
            'public service with its own limits, so a lookup can be temporarily '
            'unavailable; adding a copy by hand always works.',
          ),
          if (_longestCooldown(services) > Duration.zero)
            _paragraph(
              'A lookup source is cooling down for '
              '${_longestCooldown(services).inSeconds}s. You can add the copy '
              'by hand meanwhile.',
            ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Web lookup keys'),
          const SizedBox(height: 8),
          const _CredentialSection(
            providers: WebKeyProvider.values,
            noteKey: Key('settings-web-key-note'),
            note:
                'Optional. The free lookups and adding a copy by hand never '
                'need a key. Keys are kept in the device keystore / keychain, '
                'are never written to a backup, an export, a log or a '
                'screenshot, and are sent only to that provider. Requests are '
                'made only when you tap a web action.',
          ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Games lookup keys'),
          const SizedBox(height: 8),
          const _CredentialSection(
            providers: GamesKeyProvider.values,
            noteKey: Key('settings-games-key-note'),
            invalidatesGames: true,
            note:
                'Personal developer credentials for testing: ScanDex '
                'identifies a game barcode, Twitch issues the IGDB token and '
                'IGDB supplies game metadata. A title search sends the typed '
                'title to IGDB; a barcode lookup sends the code to ScanDex. '
                'Nothing from your collection is sent. Stored in the device '
                'keystore / keychain only, never in a backup, log or export.\n\n'
                'Twitch setup: create an application at '
                'dev.twitch.tv/console/apps (two-factor authentication must be '
                'enabled on the account), choose the confidential/website '
                'integration type, then paste its client ID and secret here. '
                'For a published app these shared credentials should live on a '
                'server-side proxy instead.',
            extra: <Widget>[
              _SetupLink(
                key: Key('settings-games-scandex-docs'),
                label: 'ScanDex API documentation',
                url: 'https://scandex.gamery.app/documentation/api/',
              ),
              _SetupLink(
                key: Key('settings-games-twitch-console'),
                label: 'Twitch developer console',
                url: 'https://dev.twitch.tv/console/apps',
              ),
              _SetupLink(
                key: Key('settings-games-igdb-docs'),
                label: 'IGDB API documentation',
                url: 'https://api-docs.igdb.com/',
              ),
              Text(
                'Game metadata by IGDB, barcode identification by ScanDex.',
                key: Key('settings-games-attribution'),
                style: LyberryType.bodyMuted,
              ),
            ],
          ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Movie lookup keys'),
          const SizedBox(height: 8),
          const _CredentialSection(
            providers: MovieKeyProvider.values,
            noteKey: Key('settings-movies-key-note'),
            invalidatesMovies: true,
            note:
                'Optional. UPCMDB identifies a DVD or Blu-ray barcode and can '
                'search films by title. A barcode lookup sends the code to '
                'UPCMDB; a title search sends the typed title and year. Nothing '
                'from your collection is sent. The key is stored in the device '
                'keystore / keychain only and is never written to a backup, '
                'export, log or screenshot. Saving or removing it never starts a '
                'lookup.\n\n'
                'UPCMDB is a third-party service used with your own key. A '
                'barcode or a title search is sent only when you ask for one.',
            extra: <Widget>[
              _SetupLink(
                key: Key('settings-movies-pricing'),
                label: 'UPCMDB pricing and signup',
                url: 'https://upcmdb.com/pricing',
              ),
              _SetupLink(
                key: Key('settings-movies-api-docs'),
                label: 'UPCMDB API reference',
                url: 'https://upcmdb.com/api',
              ),
              Text(
                'Movie metadata by UPCMDB.',
                key: Key('settings-movies-attribution'),
                style: LyberryType.bodyMuted,
              ),
            ],
          ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Privacy'),
          const SizedBox(height: 8),
          _paragraph(
            'A lookup sends only the scanned or typed code to the metadata '
            'sources; a game barcode lookup sends the code to ScanDex and the '
            'game id to IGDB, and a game title search sends the typed title to '
            'IGDB. A movie barcode or title search sends that code, title and '
            'year to UPCMDB. A cover image may be downloaded for the entry you '
            'choose. '
            'Your notes, reviews and photos are never sent. When you '
            'export a backup, that file does contain them, so keep it somewhere '
            'you trust. Importing a backup makes no network requests, and a '
            'backup never contains your API keys.',
          ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Licences'),
          const SizedBox(height: 8),
          _paragraph(
            'Oxanium (SIL Open Font License 1.1), bundled offline from the '
            'Google Fonts repository.',
          ),
          const SizedBox(height: 20),
          const SectionLabel(label: 'Version'),
          const SizedBox(height: 8),
          _row('App', 'Lyberry 0.7.0'),
        ],
      ),
    );
  }

  Duration _longestCooldown(AppServices services) {
    var longest = Duration.zero;
    for (final provider in services.metadata.providers) {
      final cooldown = services.metadata.cooldownFor(provider.id);
      if (cooldown > longest) longest = cooldown;
    }
    return longest;
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: LyberryType.body)),
          Text(value, style: LyberryType.bodyMuted),
        ],
      ),
    );
  }

  Widget _paragraph(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(text, style: LyberryType.bodyMuted),
  );

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final backup = AppServicesScope.of(context).backup;
    try {
      final BackupExportResult result = await backup.export();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = result.cancelled
            ? 'Export cancelled. Nothing was written.'
            : 'Exported ${result.items} copies and ${result.assets} images to '
                  '${result.fileName}.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
      });
      showMessage(context, describeFailure(error));
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final services = AppServicesScope.of(context);
    try {
      final BackupImportPreview? preview = await services.backup.chooseImport();
      if (!mounted) return;
      if (preview == null) {
        setState(() {
          _busy = false;
          _status = 'Import cancelled. Nothing changed.';
        });
        return;
      }
      final MergeResult? before = services.backup.lastAppliedResult;
      final MergeResult? result = await Navigator.of(context).push<MergeResult>(
        MaterialPageRoute<MergeResult>(
          builder: (_) => MergePreviewScreen(preview: preview),
        ),
      );
      if (!mounted) return;
      // If the route was dismissed while the transaction ran, report what
      // actually happened instead of a false cancellation.
      final applied = result ?? services.backup.lastAppliedResult;
      final merged = applied != null && !identical(applied, before);
      setState(() {
        _busy = false;
        _status = merged
            ? 'Merged: ${applied.added} new copies, ${applied.updated} replaced, '
                  '${applied.assetsAdded} images stored.'
            : 'Import cancelled. Nothing changed.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
      });
      showMessage(context, describeFailure(error));
    }
  }
}

/// Settings pushed as its own route, for screens that need a key.
class SettingsRouteScreen extends StatelessWidget {
  const SettingsRouteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const SettingsScreen(),
    );
  }
}

/// Tavily and DeepSeek keys, stored in the OS keystore / keychain.
///
/// The section only reads and writes locally: saving or removing a key never
/// triggers a lookup, and a saved value is never shown again.
/// One credentials group: web (Tavily/DeepSeek) or games (ScanDex/Twitch).
///
/// Keys are only read and written locally; saving or removing one never starts
/// a lookup. A games credential change additionally drops cached games answers
/// and any in-memory token, so a removed credential cannot come back.
class _CredentialSection extends StatefulWidget {
  const _CredentialSection({
    required this.providers,
    required this.noteKey,
    required this.note,
    this.invalidatesGames = false,
    this.invalidatesMovies = false,
    this.extra = const <Widget>[],
  });

  final List<CredentialKey> providers;
  final Key noteKey;
  final String note;
  final bool invalidatesGames;
  final bool invalidatesMovies;
  final List<Widget> extra;

  @override
  State<_CredentialSection> createState() => _CredentialSectionState();
}

class _CredentialSectionState extends State<_CredentialSection> {
  late final Map<CredentialKey, TextEditingController> _controllers =
      <CredentialKey, TextEditingController>{
        for (final provider in widget.providers)
          provider: TextEditingController(),
      };
  final Map<CredentialKey, bool> _configured = <CredentialKey, bool>{};
  final Map<CredentialKey, bool> _busy = <CredentialKey, bool>{};
  final Map<CredentialKey, String> _errors = <CredentialKey, String>{};
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _refresh();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final keys = AppServicesScope.of(context).keys;
    for (final provider in widget.providers) {
      var configured = false;
      String? error;
      try {
        configured = await keys.has(provider);
      } on WebLookupException catch (failure) {
        configured = false;
        error = failure.message;
      } on Object {
        configured = false;
        error = '${provider.label} status could not be read on this device.';
      }
      if (!mounted) return;
      setState(() {
        _configured[provider] = configured;
        if (error == null) {
          _errors.remove(provider);
        } else {
          _errors[provider] = error;
        }
      });
    }
  }

  Future<void> _save(CredentialKey provider) async {
    final value = _controllers[provider]!.text;
    // Captured before the await: a credential change must invalidate cached
    // games state even when this route is gone by the time storage answers.
    final services = AppServicesScope.of(context);
    setState(() => _busy[provider] = true);
    try {
      await services.keys.write(provider, value);
      _invalidate(services);
      if (!mounted) return;
      _controllers[provider]!.clear();
      setState(() {
        _configured[provider] = true;
        _busy[provider] = false;
        _errors.remove(provider);
      });
      showMessage(context, '${provider.label} saved on this device.');
    } on WebLookupException catch (error) {
      if (!mounted) return;
      setState(() => _busy[provider] = false);
      showMessage(context, error.message);
    } on Object {
      if (!mounted) return;
      setState(() => _busy[provider] = false);
      showMessage(context, '${provider.label} could not be saved.');
    }
  }

  Future<void> _remove(CredentialKey provider) async {
    final services = AppServicesScope.of(context);
    setState(() => _busy[provider] = true);
    try {
      await services.keys.remove(provider);
      _invalidate(services);
      if (!mounted) return;
      setState(() {
        _configured[provider] = false;
        _busy[provider] = false;
        _errors.remove(provider);
      });
      showMessage(context, '${provider.label} removed from this device.');
    } on WebLookupException catch (error) {
      if (!mounted) return;
      setState(() => _busy[provider] = false);
      showMessage(context, error.message);
    } on Object {
      if (!mounted) return;
      setState(() => _busy[provider] = false);
      showMessage(context, '${provider.label} could not be removed.');
    }
  }

  /// Cached game answers and the in-memory IGDB token belong to the old
  /// credentials, so both are dropped before the next lookup. Takes the
  /// services object so it never depends on mounted state.
  void _invalidate(AppServices services) {
    if (widget.invalidatesGames) {
      services.games.invalidateCredentials();
      services.metadata.invalidateCache();
    }
    if (widget.invalidatesMovies) {
      services.movies.invalidateCredentials();
      services.metadata.invalidateCache();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final provider in widget.providers) _providerBlock(provider),
        Text(widget.note, key: widget.noteKey, style: LyberryType.bodyMuted),
        for (final child in widget.extra) ...<Widget>[
          const SizedBox(height: 6),
          child,
        ],
      ],
    );
  }

  Widget _providerBlock(CredentialKey provider) {
    final configured = _configured[provider] ?? false;
    final busy = _busy[provider] ?? false;
    final error = _errors[provider];
    final controller = _controllers[provider]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: Text(provider.label, style: LyberryType.body)),
              Text(
                error != null
                    ? 'Unavailable'
                    : configured
                    ? 'Saved'
                    : 'Not configured',
                key: Key('settings-${provider.slug}-status'),
                style: LyberryType.bodyMuted,
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (error != null) ...<Widget>[
            Text(
              error,
              key: Key('settings-${provider.slug}-error'),
              style: LyberryType.bodyMuted,
            ),
            const SizedBox(height: 6),
          ],
          TextField(
            key: Key('settings-${provider.slug}-field'),
            controller: controller,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              hintText: configured
                  ? 'Paste a new value to replace it'
                  : 'Paste ${provider.label}',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                key: Key('settings-${provider.slug}-save'),
                onPressed: busy ? null : () => _save(provider),
                child: Text(configured ? 'Replace' : 'Save'),
              ),
              OutlinedButton(
                key: Key('settings-${provider.slug}-remove'),
                onPressed: busy || !configured ? null : () => _remove(provider),
                child: const Text('Remove'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small link used by the games credential help.
class _SetupLink extends StatelessWidget {
  const _SetupLink({super.key, required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => _open(context),
      icon: const Icon(Icons.open_in_new, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(padding: EdgeInsets.zero),
    );
  }

  Future<void> _open(BuildContext context) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      if (context.mounted) {
        showMessage(context, 'That link could not be opened.');
      }
    }
  }
}
