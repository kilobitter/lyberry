import 'package:flutter/foundation.dart';
import 'package:lyberry/domain/lookup.dart';
import 'package:lyberry/services/metadata_service.dart';
import 'package:lyberry/state/library_controller.dart';

enum LookupStatus { idle, loading, ready, empty, failed }

/// UI state for one identifier lookup. Candidates are only ever offered; this
/// controller never writes to the library.
class LookupController extends ChangeNotifier {
  LookupController({required MetadataService service, LookupQuery? query})
    : _service = service,
      _query = query;

  final MetadataService _service;
  LookupQuery? _query;

  LookupStatus _status = LookupStatus.idle;
  List<MetadataCandidate> _candidates = const <MetadataCandidate>[];
  List<LookupFailure> _failures = const <LookupFailure>[];
  bool _fromCache = false;
  String? _errorMessage;
  bool _disposed = false;
  int _token = 0;

  LookupStatus get status => _status;
  List<MetadataCandidate> get candidates => _candidates;
  List<LookupFailure> get failures => _failures;
  bool get fromCache => _fromCache;
  String? get errorMessage => _errorMessage;
  LookupQuery? get query => _query;

  bool get allProvidersFailed =>
      _status == LookupStatus.failed && _candidates.isEmpty;

  Future<void> search(LookupQuery query) async {
    _query = query;
    _status = LookupStatus.loading;
    _errorMessage = null;
    notifyListeners();

    final token = ++_token;
    try {
      final outcome = await _service.lookup(query);
      if (token != _token || _disposed) return;
      _candidates = outcome.candidates;
      _failures = outcome.failures;
      _fromCache = outcome.fromCache;
      _status = outcome.candidates.isNotEmpty
          ? LookupStatus.ready
          : outcome.allProvidersFailed
          ? LookupStatus.failed
          : LookupStatus.empty;
      if (_status == LookupStatus.failed) {
        _errorMessage = outcome.failures.first.message;
      }
    } on Object catch (error) {
      if (token != _token || _disposed) return;
      _candidates = const <MetadataCandidate>[];
      _status = LookupStatus.failed;
      _errorMessage = describeFailure(error);
    }
    notifyListeners();
  }

  Future<void> retry() async {
    final query = _query;
    if (query == null) return;
    await search(query);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
