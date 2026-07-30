import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/src/offline/local_paths.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _ThrowingGetFileApi extends NoopApi {
  @override
  Future<FileData?> getFile(String path) async => throw StateError('offline');
}

void main() {
  test('with no directory and no inMemory, references work but the queue does '
      'not exist', () async {
    // The stateless configuration: no directoryResolver on the app, inMemory
    // off. The REST surface still works; anything durable throws, and says
    // which of the two knobs turns it on.
    final app = WincheApp(
      'stateless',
      options: WincheOptions(storageEndpoint: Uri.parse('https://x/f')),
    );
    addTearDown(app.dispose);
    final auth = ScriptedAuthService(app);
    final storage = WincheStorage(app);

    auth.announce(WincheIdentity('user-1'));
    await app.settled;

    expect(storage.child('a/b').path, 'a/b');
    expect(storage.resumeUploads, throwsStateError);
    expect(storage.pendingUploads, throwsStateError);
  });

  test('inMemory needs no directory and wires the queue', () async {
    final app = WincheApp(
      'in-memory',
      options: WincheOptions(storageEndpoint: Uri.parse('https://x/f')),
    );
    addTearDown(app.dispose);
    final auth = ScriptedAuthService(app);
    final storage = WincheStorage(app)
      ..config = const WincheStorageConfig(inMemory: true);

    auth.announce(WincheIdentity('user-1'));
    await app.settled;

    await storage.resumeUploads();
    expect(await storage.pendingUploads(), isEmpty);
    expect(storage.transferEvents, isA<Stream<TransferEvent>>());
  });

  test('enqueue+cache uploadPath stages through the controller', () async {
    final tmp = Directory.systemTemp.createTempSync('winche-facade-pin');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // Best effort: the store may still hold a handle on Windows.
      }
    });

    final app = WincheApp('facade-pin');
    addTearDown(app.dispose);
    final storage = WincheStorage(app)
      ..config = const WincheStorageConfig(
        retryMaxAttempts: 0,
        retryPollInterval: Duration(hours: 1),
      );
    storage.debugBindStore(
      _ThrowingGetFileApi(), // getFile throws -> upload fails after staging
      MemoryStorageLocalStore(),
      directoryResolver: () async => tmp.path,
    );

    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);
    final task =
        storage.child('a/b.png').uploadPath(src.path, enqueue: true, cache: true);
    await task.whenDone.catchError((_) => null);

    expect(File(stagingFilePath(tmp.path, 'a/b.png')).existsSync(), isTrue);
  });
}
