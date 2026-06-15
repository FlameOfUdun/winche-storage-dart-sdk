import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('fromStatus returns the matching subclass', () {
    expect(WincheStorageException.fromStatus(StorageErrorStatus.notFound, 'x'),
        isA<StorageNotFoundException>());
    expect(
        WincheStorageException.fromStatus(
            StorageErrorStatus.permissionDenied, 'x'),
        isA<StoragePermissionDeniedException>());
    expect(
        WincheStorageException.fromStatus(StorageErrorStatus.unavailable, 'x'),
        isA<StorageUnavailableException>());
    expect(WincheStorageException.fromStatus(StorageErrorStatus.unknown, 'x'),
        isA<StorageUnknownException>());
  });

  test('statusCode reads from details', () {
    const e = StorageNotFoundException('missing', {'statusCode': 404});
    expect(e.status, StorageErrorStatus.notFound);
    expect(e.statusCode, 404);
    expect(e.message, 'missing');
  });
}
