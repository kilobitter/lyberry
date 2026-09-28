import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:lyberry/services/photo_source.dart';

import '../support/test_support.dart';

class _LostDataPlatform extends ImagePickerPlatform {
  _LostDataPlatform(this.response);

  final LostDataResponse response;
  int calls = 0;

  @override
  Future<LostDataResponse> getLostData() async {
    calls++;
    return response;
  }
}

void main() {
  late ImagePickerPlatform original;

  setUp(() => original = ImagePickerPlatform.instance);
  tearDown(() => ImagePickerPlatform.instance = original);

  test('surfaces a lost-data exception as a user-facing failure', () async {
    ImagePickerPlatform.instance = _LostDataPlatform(
      LostDataResponse(
        exception: PlatformException(code: 'camera_access_denied'),
      ),
    );

    await expectLater(
      ImagePickerPhotoSource().recoverLostPhotos(),
      throwsA(
        isA<PhotoSourceFailure>().having(
          (error) => error.message,
          'message',
          contains('Camera access is off'),
        ),
      ),
    );
  });

  test('returns an empty list when there is nothing to recover', () async {
    ImagePickerPlatform.instance = _LostDataPlatform(LostDataResponse.empty());

    expect(await ImagePickerPhotoSource().recoverLostPhotos(), isEmpty);
  });

  test('returns recovered files', () async {
    final bytes = pngBytes();
    final file = XFile.fromData(
      bytes,
      name: 'recovered.png',
      mimeType: 'image/png',
    );
    ImagePickerPlatform.instance = _LostDataPlatform(
      LostDataResponse(files: <XFile>[file]),
    );

    final recovered = await ImagePickerPhotoSource().recoverLostPhotos();
    expect(recovered, hasLength(1));
    expect(recovered.single.bytes, orderedEquals(bytes));
  });
}
