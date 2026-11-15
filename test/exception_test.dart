// The deprecated names are exercised on purpose: they must keep working for a release.
// ignore_for_file: deprecated_member_use
import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('of keeps the code, reason and status, and is a WincheException', () {
    final e = WincheStorageException.of(WincheErrorCode.invalidArgument, 'Too big.', reason: 'too-large', statusCode: 400);
    expect([e.code, e.reason, e.statusCode, e.message], [WincheErrorCode.invalidArgument, 'too-large', 400, 'Too big.']);
    expect(e, isA<WincheException>());
    expect(e.isTransient, isFalse);
    expect(WincheStorageException.of(WincheErrorCode.unavailable, 'x').isTransient, isTrue);
    expect(WincheStorageException.of(WincheErrorCode.alreadyExists, 'x').code, WincheErrorCode.alreadyExists);
  });

  test('for this release, of still throws the old subclasses, so their catches keep working', () {
    expect(WincheStorageException.of(WincheErrorCode.notFound, 'x'), isA<StorageNotFoundException>());
    expect(WincheStorageException.of(WincheErrorCode.permissionDenied, 'x'), isA<StoragePermissionDeniedException>());
    expect(WincheStorageException.of(WincheErrorCode.unavailable, 'x'), isA<StorageUnavailableException>());
    expect(WincheStorageException.of(WincheErrorCode.unknown, 'x', reason: 'r').reason, 'r');
  });

  test('the old status, details and fromStatus still work', () {
    expect(WincheStorageException.fromStatus(StorageErrorStatus.notFound, 'x'), isA<StorageNotFoundException>());
    final e = StorageNotFoundException('missing', {'statusCode': 404});
    expect([e.status, e.statusCode, e.details, e.code], [StorageErrorStatus.notFound, 404, {'statusCode': 404}, WincheErrorCode.notFound]);
  });
}
