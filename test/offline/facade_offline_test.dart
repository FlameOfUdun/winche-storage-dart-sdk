import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';
import 'package:winche_storage/src/offline/local_paths.dart';

import '../support/noop_api.dart';

class _ThrowingGetFileApi extends NoopApi {
  @override
  Future<FileData?> getFile(String path) async => throw StateError('offline');
}

void main() {
  test('defaults off: child works with no store, resume throws', () {
    final s = WincheStorage(WincheStorageConfig(uri: Uri.parse('https://x/f')));
    final ref = s.child('a/b');
    expect(ref.path, 'a/b');
    expect(s.resumeDownloads, throwsStateError);
    expect(s.resumeUploads, throwsStateError);
    expect(() => s.pendingTransfers(), throwsStateError);
  });

  test('pendingTransfers returns the queue when auto-resume is on', () async {
    final s = WincheStorage.withStore(
      NoopApi(),
      MemoryStorageLocalStore(),
    );
    expect(await s.pendingTransfers(), isEmpty);
    await s.dispose();
  });

  test('inMemory auto-resume needs no directory and wires resume', () async {
    final s = WincheStorage(WincheStorageConfig(
      uri: Uri.parse('https://x/f'),
      inMemory: true,
    ));
    await s.resumeDownloads();
    await s.resumeUploads();
    expect(s.transferEvents, isA<Stream<TransferEvent>>());
    await s.dispose();
  });

  test('facade: enqueue+cache uploadPath stages through the controller',
      () async {
    final tmp = Directory.systemTemp.createTempSync('winche-facade-pin');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final storage = WincheStorage.withStore(
      _ThrowingGetFileApi(), // getFile throws -> upload fails after staging
      MemoryStorageLocalStore(),
      directoryResolver: () async => tmp.path,
      retryMaxAttempts: 0,
      retryPollInterval: const Duration(hours: 1),
    );
    addTearDown(storage.dispose);

    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);
    final task = storage
        .child('a/b.png')
        .uploadPath(src.path, enqueue: true, cache: true);
    await task.whenDone.catchError((_) => null);

    expect(File(stagingFilePath(tmp.path, 'a/b.png')).existsSync(), isTrue);
  });
}
