import 'package:flutter/foundation.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/movies/movie_catalog.dart';

enum MovieSearchStatus { idle, running, ready, empty, failed }

/// State for one explicit "search movies by title" request.
///
/// One request per submit, never per keystroke; a late answer from an earlier
/// query (or a disposed screen) is ignored. The optional year is validated
/// before the button is enabled, so no malformed query is ever encoded.
class MovieSearchController extends ChangeNotifier {
  MovieSearchController({
    required MovieCatalog catalog,
    Clock clock = const SystemClock(),
  }) : _catalog = catalog,
       _maxYear = clock.nowUtc().year + 2;

  /// Earliest year a film release can plausibly carry.
  static const int minYear = 1878;

  final MovieCatalog _catalog;
  final int _maxYear;

  String _title = '';
  String _yearText = '';
  String _searchedTitle = '';
  int? _searchedYear;
  MovieSearchStatus _status = MovieSearchStatus.idle;
  List<MetadataCandidate> _candidates = const <MetadataCandidate>[];
  String? _errorMessage;
  int _token = 0;
  bool _disposed = false;

  String get title => _title;
  String get yearText => _yearText;
  MovieSearchStatus get status => _status;
  List<MetadataCandidate> get candidates => _candidates;
  String? get errorMessage => _errorMessage;
  bool get isRunning => _status == MovieSearchStatus.running;

  /// `null` when the optional year field is usable, otherwise the message to
  /// show under the field.
  String? get yearProblem {
    final text = _yearText.trim();
    if (text.isEmpty) return null;
    if (text.length != 4 || int.tryParse(text) == null) {
      return 'Use a four-digit year, or leave it empty.';
    }
    final year = int.parse(text);
    if (year < minYear || year > _maxYear) {
      return 'Use a year between $minYear and $_maxYear.';
    }
    return null;
  }

  bool get canSubmit =>
      _title.trim().isNotEmpty && yearProblem == null && !isRunning;

  void setTitle(String value) {
    if (_title == value) return;
    _title = value;
    // A different title invalidates the previous answer *and* any request still
    // running: results must never appear under a title that was not searched.
    _invalidateAnswer();
    notifyListeners();
  }

  void setYear(String value) {
    if (_yearText == value) return;
    _yearText = value;
    _invalidateAnswer();
    notifyListeners();
  }

  /// Drops the published answer and invalidates the in-flight request, so a late
  /// success *or* a late error can never land under an edited field.
  void _invalidateAnswer() {
    _token++;
    _status = MovieSearchStatus.idle;
    _candidates = const <MetadataCandidate>[];
    _errorMessage = null;
  }

  Future<void> submit() async {
    // One request per submit, even when the keyboard action fires while the
    // previous answer is still on its way.
    if (isRunning) return;
    final title = _title.trim();
    final problem = yearProblem;
    if (title.isEmpty || problem != null) return;
    final year = int.tryParse(_yearText.trim());
    _searchedTitle = title;
    _searchedYear = year;
    _status = MovieSearchStatus.running;
    _errorMessage = null;
    _candidates = const <MetadataCandidate>[];
    final token = ++_token;
    notifyListeners();

    MovieSearchOutcome outcome;
    try {
      outcome = await _catalog.searchByTitle(title, year: year);
    } on Object {
      if (token != _token || _disposed) return;
      _status = MovieSearchStatus.failed;
      _errorMessage = 'The movie search did not finish.';
      notifyListeners();
      return;
    }
    if (token != _token || _disposed) return;
    // A late answer for a title that is no longer in the field is dropped.
    if (_title.trim() != _searchedTitle ||
        int.tryParse(_yearText.trim()) != _searchedYear) {
      return;
    }

    _candidates = outcome.candidates;
    if (outcome.candidates.isNotEmpty) {
      _status = MovieSearchStatus.ready;
      _errorMessage = null;
    } else if (outcome.failure != null) {
      _status = MovieSearchStatus.failed;
      _errorMessage = outcome.failure!.message;
    } else {
      _status = MovieSearchStatus.empty;
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
