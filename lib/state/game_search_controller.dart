import 'package:flutter/foundation.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/games/game_catalog.dart';

enum GameSearchStatus { idle, running, ready, empty, failed }

/// State for one explicit "search games by title" request.
///
/// One request per submit, never per keystroke; a late answer from an earlier
/// query (or a disposed screen) is ignored.
class GameSearchController extends ChangeNotifier {
  GameSearchController({required GameCatalog catalog}) : _catalog = catalog;

  final GameCatalog _catalog;

  String _query = '';
  String _searchedTitle = '';
  GameSearchStatus _status = GameSearchStatus.idle;
  List<MetadataCandidate> _candidates = const <MetadataCandidate>[];
  String? _errorMessage;
  int _token = 0;
  bool _disposed = false;

  String get query => _query;
  GameSearchStatus get status => _status;
  List<MetadataCandidate> get candidates => _candidates;
  String? get errorMessage => _errorMessage;
  bool get isRunning => _status == GameSearchStatus.running;
  bool get canSubmit => _query.trim().isNotEmpty && !isRunning;

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    // A different title invalidates the previous answer: results must never
    // appear under a title that was not searched.
    if (_status != GameSearchStatus.idle && value.trim() != _searchedTitle) {
      _status = GameSearchStatus.idle;
      _candidates = const <MetadataCandidate>[];
      _errorMessage = null;
    }
    // Only the submit button's enabled state depends on this; no request is
    // made per keystroke.
    notifyListeners();
  }

  Future<void> submit() async {
    final title = _query.trim();
    if (title.isEmpty || isRunning) return;
    _searchedTitle = title;
    _status = GameSearchStatus.running;
    _errorMessage = null;
    _candidates = const <MetadataCandidate>[];
    final token = ++_token;
    notifyListeners();

    GameSearchOutcome outcome;
    try {
      outcome = await _catalog.searchByTitle(title);
    } on Object {
      if (token != _token || _disposed) return;
      _status = GameSearchStatus.failed;
      _errorMessage = 'The games search did not finish.';
      notifyListeners();
      return;
    }
    if (token != _token || _disposed) return;

    _candidates = outcome.candidates;
    if (outcome.candidates.isNotEmpty) {
      _status = GameSearchStatus.ready;
      _errorMessage = null;
    } else if (outcome.failure != null) {
      _status = GameSearchStatus.failed;
      _errorMessage = outcome.failure!.message;
    } else {
      _status = GameSearchStatus.empty;
      _errorMessage = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    super.dispose();
  }
}
