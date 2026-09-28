import 'package:flutter/foundation.dart';
import 'package:lyberry/domain/identifier.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/domain/media_type.dart';
import 'package:lyberry/domain/web_lookup.dart';
import 'package:lyberry/services/web/web_lookup_service.dart';

enum WebLookupMode {
  search('Search the web', 'Find product pages for this code'),
  link('Import from link', 'Read a product page you paste');

  const WebLookupMode(this.label, this.hint);

  final String label;
  final String hint;
}

enum WebLookupStatus { idle, running, ready, empty, failed }

/// UI state for one explicit web lookup.
///
/// Nothing here runs by itself: [runSearch] and [runLink] are only called from
/// an explicit user action, and a second action while one is running is
/// absorbed instead of paying twice.
class WebLookupController extends ChangeNotifier {
  WebLookupController({
    required WebLookupService service,
    required this.identifier,
    this.mediumHint,
    WebLookupMode mode = WebLookupMode.search,
    String urlText = '',
  }) : _service = service,
       _mode = mode,
       _urlText = urlText;

  final WebLookupService _service;
  final NormalizedIdentifier identifier;

  MediaType? mediumHint;
  WebLookupMode _mode;
  String _urlText;

  WebLookupStatus _status = WebLookupStatus.idle;
  List<WebCandidate> _candidates = const <WebCandidate>[];
  List<WebLookupFailure> _failures = const <WebLookupFailure>[];
  List<WebSourcePage> _pages = const <WebSourcePage>[];
  bool _usedExtraction = false;
  String? _errorMessage;
  bool _disposed = false;
  int _token = 0;

  /// Immutable per-operation cancellation identity: each run owns a generation,
  /// and cancelling marks that generation forever. A later tap starts a new
  /// generation, so it can never reactivate a cancelled pipeline.
  int _generation = 0;
  int? _cancelledGeneration;

  WebLookupStatus get status => _status;
  WebLookupMode get mode => _mode;
  String get urlText => _urlText;
  List<WebCandidate> get candidates => _candidates;
  List<WebLookupFailure> get failures => _failures;
  List<WebSourcePage> get pages => _pages;
  bool get usedExtraction => _usedExtraction;
  String? get errorMessage => _errorMessage;
  bool get isRunning => _status == WebLookupStatus.running;

  /// The first stage that needs a key the user has not configured.
  WebLookupFailure? get missingKey {
    for (final failure in _failures) {
      if (failure.kind == WebFailureKind.missingKey) return failure;
    }
    return null;
  }

  /// True when the network was attempted and nothing usable came back.
  bool get needsManualFallback =>
      _status == WebLookupStatus.empty || _status == WebLookupStatus.failed;

  LookupQuery get query =>
      LookupQuery(identifier: identifier, mediumHint: mediumHint);

  void setMode(WebLookupMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
  }

  void setMediumHint(MediaType? medium) {
    if (mediumHint == medium) return;
    mediumHint = medium;
    notifyListeners();
  }

  void setUrlText(String value) {
    _urlText = value;
  }

  /// Explicit search action. Requires the Tavily key.
  Future<void> runSearch() async {
    if (isRunning) return;
    final generation = ++_generation;
    await _run(
      generation,
      (isCancelled) => _service.search(query, isCancelled: isCancelled),
    );
  }

  /// Explicit "read this page" action for the pasted link.
  Future<void> runLink() async {
    if (isRunning) return;
    final raw = _urlText.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        !uri.hasAuthority) {
      _fail(
        const WebLookupFailure(
          stage: WebLookupStage.fetch,
          label: 'Link',
          kind: WebFailureKind.blocked,
          message:
              'Paste a full public https product link, for example '
              'https://shop.example/item.',
        ),
      );
      return;
    }
    final generation = ++_generation;
    await _run(
      generation,
      (isCancelled) => _service.importLink(
        identifier: identifier,
        url: uri,
        mediumHint: mediumHint,
        isCancelled: isCancelled,
      ),
    );
  }

  /// Stops the running lookup. Late answers are ignored.
  void cancel() {
    if (!isRunning) return;
    _cancelledGeneration = _generation;
    _token++;
    _status = WebLookupStatus.empty;
    _candidates = const <WebCandidate>[];
    _failures = const <WebLookupFailure>[
      WebLookupFailure(
        stage: WebLookupStage.search,
        label: 'Web lookup',
        kind: WebFailureKind.cancelled,
        message: 'Stopped. Nothing was saved.',
      ),
    ];
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _run(
    int generation,
    Future<WebLookupOutcome> Function(bool Function() isCancelled) task,
  ) async {
    _status = WebLookupStatus.running;
    _errorMessage = null;
    _failures = const <WebLookupFailure>[];
    notifyListeners();

    final token = ++_token;
    // Cancellation is sticky per captured run: it stays true when this run is
    // explicitly cancelled, when a newer run has taken over, and when the
    // controller is disposed. Nothing that happens later can revive it.
    bool isCancelled() =>
        _disposed ||
        generation != _generation ||
        _cancelledGeneration == generation;
    WebLookupOutcome outcome;
    try {
      outcome = await task(isCancelled);
    } on Object {
      if (token != _token || _disposed) return;
      _fail(
        WebLookupFailure(
          stage: WebLookupStage.search,
          label: 'Web lookup',
          kind: WebFailureKind.unavailable,
          message: 'The web lookup could not finish.',
        ),
      );
      return;
    }
    if (token != _token || _disposed) return;
    _apply(outcome);
  }

  void _apply(WebLookupOutcome outcome) {
    _candidates = outcome.candidates;
    _failures = outcome.failures;
    _pages = outcome.pages;
    _usedExtraction = outcome.usedExtraction;
    if (outcome.candidates.isNotEmpty) {
      _status = WebLookupStatus.ready;
      _errorMessage = null;
    } else if (_failures.any(
      (failure) => failure.kind == WebFailureKind.cancelled,
    )) {
      _status = WebLookupStatus.empty;
      _errorMessage = null;
    } else if (_failures.isEmpty) {
      _status = WebLookupStatus.empty;
      _errorMessage =
          'No page had a usable product record for ${identifier.value}.';
    } else {
      _status = WebLookupStatus.failed;
      _errorMessage = _failures.first.message;
    }
    notifyListeners();
  }

  void _fail(WebLookupFailure failure) {
    _candidates = const <WebCandidate>[];
    _pages = const <WebSourcePage>[];
    _usedExtraction = false;
    _failures = <WebLookupFailure>[failure];
    _status = WebLookupStatus.failed;
    _errorMessage = failure.message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
