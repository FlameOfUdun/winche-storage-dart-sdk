import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('OfflineCopyStatus is exported with the expected values', () {
    expect(OfflineCopyStatus.values, [
      OfflineCopyStatus.notPinned,
      OfflineCopyStatus.upToDate,
      OfflineCopyStatus.contentChanged,
      OfflineCopyStatus.remoteDeleted,
      OfflineCopyStatus.unknown,
    ]);
  });
}
