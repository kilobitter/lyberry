import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// Photo bytes returned by a camera or gallery pick.
class PickedPhoto {
  const PickedPhoto({required this.bytes, this.sourceName});

  final Uint8List bytes;
  final String? sourceName;
}

/// Failure that should be shown to the user; cancellations are not failures.
class PhotoSourceFailure implements Exception {
  const PhotoSourceFailure(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'PhotoSourceFailure: $message';
}

/// Injected seam so widget tests never touch the camera or gallery.
abstract interface class PhotoSource {
  /// Returns `null` when the user cancels or denies access.
  Future<PickedPhoto?> capture();

  /// Returns `null` when the user cancels.
  Future<PickedPhoto?> pick();

  /// Photos captured before Android reclaimed the activity, if any.
  Future<List<PickedPhoto>> recoverLostPhotos();
}

class ImagePickerPhotoSource implements PhotoSource {
  ImagePickerPhotoSource([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Downscales large captures so they fit the 5 MiB storage bound.
  static const double _maxDimension = 2560;
  static const int _quality = 90;

  @override
  Future<PickedPhoto?> capture() => _pick(ImageSource.camera);

  @override
  Future<PickedPhoto?> pick() => _pick(ImageSource.gallery);

  Future<PickedPhoto?> _pick(ImageSource source) async {
    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: source,
        maxWidth: _maxDimension,
        maxHeight: _maxDimension,
        imageQuality: _quality,
      );
    } on PlatformException catch (error) {
      throw PhotoSourceFailure(_describe(error), error);
    } on Exception catch (error) {
      throw PhotoSourceFailure('The photo could not be opened.', error);
    }
    if (file == null) return null;
    try {
      return PickedPhoto(
        bytes: await file.readAsBytes(),
        sourceName: file.name,
      );
    } on Exception catch (error) {
      throw PhotoSourceFailure('The photo could not be read.', error);
    }
  }

  @override
  Future<List<PickedPhoto>> recoverLostPhotos() async {
    final LostDataResponse response;
    try {
      response = await _picker.retrieveLostData();
    } on PlatformException catch (error) {
      throw PhotoSourceFailure(_describe(error), error);
    }
    final failure = response.exception;
    if (failure != null) {
      throw PhotoSourceFailure(_describe(failure), failure);
    }
    if (response.isEmpty) return const <PickedPhoto>[];
    final recovered = <PickedPhoto>[];
    for (final file in response.files ?? const <XFile>[]) {
      try {
        recovered.add(
          PickedPhoto(bytes: await file.readAsBytes(), sourceName: file.name),
        );
      } on Exception catch (error) {
        throw PhotoSourceFailure(
          'A photo from the last session could not be read.',
          error,
        );
      }
    }
    return recovered;
  }

  String _describe(PlatformException error) => switch (error.code) {
    'camera_access_denied' =>
      'Camera access is off. Allow it in system settings, or pick a photo.',
    'photo_access_denied' =>
      'Photo access is off. Allow it in system settings, or take a photo.',
    _ => 'The photo could not be added (${error.code}).',
  };
}
