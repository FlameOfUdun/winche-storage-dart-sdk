import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('defaults off: child works with no store, resume throws', () {
    final s = WincheStorage(WincheStorageConfig(uri: Uri.parse('https://x/f')));
    final ref = s.child('a/b');
    expect(ref.path, 'a/b');
    expect(s.resumeDownloads, throwsStateError);
    expect(s.resumeUploads, throwsStateError);
  });

  test('enableAutoResume requires directoryResolver on native', () {
    expect(
      () => WincheStorage(WincheStorageConfig(
        uri: Uri.parse('https://x/f'),
        enableAutoResume: true,
      )),
      throwsArgumentError,
    );
  });

  test('enableOfflineCache requires directoryResolver on native', () {
    expect(
      () => WincheStorage(WincheStorageConfig(
        uri: Uri.parse('https://x/f'),
        enableOfflineCache: true,
      )),
      throwsArgumentError,
    );
  });

  test('inMemory auto-resume needs no directory and wires resume', () async {
    final s = WincheStorage(WincheStorageConfig(
      uri: Uri.parse('https://x/f'),
      enableAutoResume: true,
      inMemory: true,
    ));
    await s.resumeDownloads();
    await s.resumeUploads();
    expect(s.transferEvents, isA<Stream<TransferEvent>>());
    await s.dispose();
  });
}
