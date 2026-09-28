import 'package:lyberry/services/backup_service.dart';

/// File-dialog seam for backup tests: no platform channels involved.
class FakeSnapshotIo implements SnapshotIo {
  FakeSnapshotIo({this.pickResult, this.saveResult = true});

  /// Returned by [pickBackup]; `null` simulates the user cancelling.
  PickedBackup? pickResult;

  /// Returned by [saveBackup]; `false` simulates cancelling the save dialog.
  bool saveResult;

  String? savedFileName;
  String? savedContents;
  int pickCalls = 0;

  @override
  Future<PickedBackup?> pickBackup() async {
    pickCalls++;
    return pickResult;
  }

  @override
  Future<bool> saveBackup({
    required String fileName,
    required String contents,
  }) async {
    savedFileName = fileName;
    savedContents = contents;
    return saveResult;
  }
}
