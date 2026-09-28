import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:lyberry/data/media_repository.dart';
import 'package:lyberry/domain/clock.dart';
import 'package:lyberry/domain/library_snapshot.dart';

/// User-facing backup failure (oversized file, unreadable pick, save failure).
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => 'BackupException: $message';
}

/// A picked backup file, already read in full under the size cap.
class PickedBackup {
  const PickedBackup({
    required this.fileName,
    required this.contents,
    required this.byteLength,
  });

  final String fileName;
  final String contents;
  final int byteLength;
}

/// File picking seam so backup flows are testable without a file dialog.
abstract interface class SnapshotIo {
  /// Returns `null` when the user cancels.
  Future<PickedBackup?> pickBackup();

  /// Returns `false` when the user cancels the save dialog.
  Future<bool> saveBackup({required String fileName, required String contents});
}

class FilePickerSnapshotIo implements SnapshotIo {
  const FilePickerSnapshotIo({this.maxBytes = SnapshotCodec.maxFileBytes});

  final int maxBytes;

  @override
  Future<PickedBackup?> pickBackup() async {
    final PlatformFile? file;
    try {
      file = await FilePicker.pickFile(
        dialogTitle: 'Choose a Lyberry backup',
        type: FileType.custom,
        allowedExtensions: <String>['json'],
      );
    } on PlatformException catch (error) {
      throw BackupException('The file picker failed (${error.code}).');
    }
    if (file == null) return null;

    final knownLength = file.lengthSync();
    if (knownLength != null && knownLength > maxBytes) {
      throw const BackupException('That backup is larger than 100 MiB.');
    }

    // Stream with a hard cap so a huge file is never fully allocated.
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in file.readAsByteStream()) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw const BackupException('That backup is larger than 100 MiB.');
        }
      }
    } on FileSystemException {
      throw const BackupException('That backup could not be read.');
    }
    final bytes = builder.takeBytes();
    return PickedBackup(
      fileName: file.name,
      contents: _decodeUtf8(bytes),
      byteLength: bytes.length,
    );
  }

  @override
  Future<bool> saveBackup({
    required String fileName,
    required String contents,
  }) async {
    final Uri? saved;
    try {
      saved = await FilePicker.saveFile(
        dialogTitle: 'Save Lyberry backup',
        fileName: fileName,
        bytes: utf8.encode(contents),
        mimeType: 'application/json',
        type: FileType.custom,
        allowedExtensions: <String>['json'],
      );
    } on PlatformException catch (error) {
      throw BackupException('The backup could not be saved (${error.code}).');
    }
    return saved != null;
  }

  String _decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const BackupException('That backup is not valid UTF-8 text.');
    }
  }
}

class BackupExportResult {
  const BackupExportResult({
    required this.cancelled,
    required this.fileName,
    required this.items,
    required this.assets,
    required this.byteLength,
  });

  final bool cancelled;
  final String fileName;
  final int items;
  final int assets;
  final int byteLength;
}

/// Preview shown before anything is written.
class BackupImportPreview {
  const BackupImportPreview({
    required this.fileName,
    required this.byteLength,
    required this.snapshot,
    required this.added,
    required this.updated,
  });

  final String fileName;
  final int byteLength;
  final LibrarySnapshot snapshot;
  final int added;
  final int updated;

  int get total => added + updated;
}

/// Portable export and merge import.
///
/// Import validates the whole file before a single row changes, and export
/// bounds are checked before anything is handed to the platform file dialog.
class BackupService {
  BackupService({
    required MediaRepository repository,
    required SnapshotIo io,
    Clock? clock,
    bool useIsolate = true,
    this.limits = SnapshotCodec.defaultLimits,
  }) : _repository = repository,
       _io = io,
       _clock = clock ?? const SystemClock(),
       _useIsolate = useIsolate;

  final MediaRepository _repository;
  final SnapshotIo _io;
  final Clock _clock;

  /// When true (the default), encoding and decoding run on a worker isolate.
  final bool _useIsolate;

  /// Caps applied to export and import; tests inject tiny values.
  final SnapshotLimits limits;

  /// Result of the most recent successful merge.
  ///
  /// The preview screen normally returns it to the caller, but if the route
  /// disappears mid-apply (for example a system back that the platform honours
  /// anyway) the caller can still report what actually happened.
  MergeResult? lastAppliedResult;

  Future<BackupExportResult> export() async {
    final snapshot = await _repository.exportSnapshot();
    // Capture sendable locals only: the worker must never see `this` with its
    // repository and platform file picker.
    final payload = await _encode(snapshot, limits);
    final fileName = 'lyberry-${_stamp(_clock.nowUtc())}.lyberry.json';
    final saved = await _io.saveBackup(fileName: fileName, contents: payload);
    return BackupExportResult(
      cancelled: !saved,
      fileName: fileName,
      items: snapshot.items.length,
      assets: snapshot.assets.length,
      byteLength: SnapshotCodec.exactUtf8Length(payload),
    );
  }

  /// Returns `null` when the user cancels the picker.
  Future<BackupImportPreview?> chooseImport() async {
    final picked = await _io.pickBackup();
    if (picked == null) return null;

    final snapshot = await _decode(picked.contents);
    final existing = await _repository.existingItemIds();
    var added = 0;
    var updated = 0;
    for (final item in snapshot.items) {
      if (existing.contains(item.id)) {
        updated++;
      } else {
        added++;
      }
    }
    return BackupImportPreview(
      fileName: picked.fileName,
      byteLength: picked.byteLength,
      snapshot: snapshot,
      added: added,
      updated: updated,
    );
  }

  /// Single atomic apply; the user confirms the preview first.
  Future<MergeResult> apply(LibrarySnapshot snapshot) async {
    final result = await _repository.mergeSnapshot(snapshot);
    lastAppliedResult = result;
    return result;
  }

  Future<LibrarySnapshot> _decode(String contents) {
    final limits = this.limits;
    if (!_useIsolate) {
      return Future<LibrarySnapshot>.value(
        SnapshotCodec.decode(contents, limits: limits),
      );
    }
    return Isolate.run(() => SnapshotCodec.decode(contents, limits: limits));
  }

  Future<String> _encode(LibrarySnapshot snapshot, SnapshotLimits limits) {
    if (!_useIsolate) {
      return Future<String>.value(
        SnapshotCodec.encode(snapshot, limits: limits),
      );
    }
    return Isolate.run(() => SnapshotCodec.encode(snapshot, limits: limits));
  }

  String _stamp(DateTime utc) {
    final value = utc.toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }
}
