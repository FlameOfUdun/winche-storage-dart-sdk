import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/lazy_storage_local_store.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Hangs on the first server call until released, so a test can close the SDK
/// with a transfer genuinely in flight.
class _HangingApi extends NoopApi {
  final _gate = Completer<void>();
  var started = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<FileData?> getFile(String path) async {
    if (!started.isCompleted) started.complete();
    await _gate.future;
    return null;
  }

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    if (!started.isCompleted) started.complete();
    await _gate.future;
    return DownloadSession(url: 'http://127.0.0.1:1/x', expiresAt: DateTime.utc(2030));
  }
}

Future<void> _until(Future<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition never became true within $timeout');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-close'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  WincheStorage open(String ns, {WincheStorageApi? api}) => api == null
      ? WincheStorage(WincheStorageConfig(
          uri: Uri.parse('http://127.0.0.1:1/f'),
          namespaceResolver: () => ns,
          directoryResolver: () async => tmp.path,
          retryBaseDelay: const Duration(milliseconds: 5),
          retryMaxDelay: const Duration(milliseconds: 10),
          retryPollInterval: const Duration(hours: 1),
        ))
      : WincheStorage.withStore(
          api,
          MemoryStorageLocalStore(),
          directoryResolver: () async => tmp.path,
          retryBaseDelay: const Duration(milliseconds: 5),
          retryMaxDelay: const Duration(milliseconds: 10),
          retryPollInterval: const Duration(hours: 1),
        );

  test('close is idempotent and flips isClosed', () async {
    final s = open('u');
    expect(s.isClosed, isFalse);
    await s.close();
    expect(s.isClosed, isTrue);
    await s.close(); // must not throw or double-close the store
    await s.close();
  });

  test('every entry point throws StateError after close', () async {
    final s = open('u');
    await s.close();

    expect(() => s.child('a/b'), throwsStateError);
    expect(() => s.resumeTransfers(), throwsStateError);
    expect(() => s.resumeUploads(), throwsStateError);
    expect(() => s.resumeDownloads(), throwsStateError);
    expect(() => s.pendingTransfers(), throwsStateError);
    expect(() => s.uploadFor('a/b'), throwsStateError);
    expect(() => s.downloadFor('a/b'), throwsStateError);
    expect(() => s.transferEvents, throwsStateError);
    expect(() => s.clearOfflineCache(), throwsStateError);
  });

  test('closing mid-transfer raises no "database is closed"', () async {
    final api = _HangingApi();
    final s = open('u', api: api);
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);

    final task = s.child('a/b.txt').uploadPath(src.path, enqueue: true);
    task.whenDone.ignore();
    await api.started.future; // genuinely in flight

    // Uncatchable sembast errors surface as unhandled async errors, not as a
    // throw from close() — so watch the zone rather than just awaiting.
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await s.close();
      api.release();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }, (e, _) => errors.add(e))!;

    expect(errors, isEmpty, reason: 'close raced the store: $errors');
  });

  test('close does not wait on the network', () async {
    final api = _HangingApi();
    final s = open('u', api: api);
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
    s.child('a/b.txt').uploadPath(src.path, enqueue: true).whenDone.ignore();
    await api.started.future;

    // The request never completes; close must still return promptly.
    await s.close().timeout(const Duration(seconds: 2));
    api.release();
  });

  test('a one-shot transfer is cancelled, not left running', () async {
    final api = _HangingApi();
    final s = open('u', api: api);

    final task = s.child('a/b.txt').download(p.join(tmp.path, 'out.bin'));
    await api.started.future;

    await s.close();
    await expectLater(
        task.whenDone, throwsA(isA<StorageCancelledException>()));
    api.release();
  });

  test('a durable transfer is left resumable, not failed', () async {
    final s = open('u');
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
    s.child('a/b.txt').uploadPath(src.path, enqueue: true).whenDone.ignore();
    await _until(() async => (await s.pendingTransfers()).isNotEmpty);
    await s.close();

    // A fresh client over the same namespace picks the work back up. Nothing is
    // left marked `running`, which on a new process would mean "someone else is
    // driving this".
    final again = open('u');
    final records = await again.pendingTransfers();
    expect(records, hasLength(1));
    expect(records.single.status, isNot(TransferStatus.running));
    expect(records.single.path, 'a/b.txt');
    await again.close();
  });

  test('a scheduled retry does not fire after close', () async {
    final s = open('u');
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
    s.child('a/b.txt').uploadPath(src.path, enqueue: true).whenDone.ignore();
    await _until(() async => (await s.pendingTransfers()).isNotEmpty);

    final errors = <Object>[];
    await runZonedGuarded(() async {
      await s.close();
      // Comfortably longer than the 5–10 ms backoff: an untracked timer would
      // fire here, into a closed store.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }, (e, _) => errors.add(e))!;

    expect(errors, isEmpty, reason: 'a retry timer outlived close: $errors');
  });

  group('LazyStorageLocalStore after close', () {
    test('degrades to no-ops rather than throwing', () async {
      final store = LazyStorageLocalStore(
          () async => MemoryStorageLocalStore());
      await store.putCatalog('a', {'x': 1});
      expect(await store.getCatalog('a'), isNotNull);

      await store.close();
      expect(store.isClosed, isTrue);

      // "Nothing cached" is the safe reading of a store that is gone; throwing
      // here would surface as an uncatchable async error in a straggler.
      expect(await store.getCatalog('a'), isNull);
      expect(await store.allCatalog(), isEmpty);
      expect(await store.allTransfers(), isEmpty);
      expect(await store.getMeta('k'), isNull);
      expect(await store.nextTransferSeq(), 0);
      await store.putCatalog('b', {'x': 1});
      await store.putTransfer(1, {'x': 1});
      await store.removeCatalog('a');
      await store.removeTransfer(1);
      await store.putMeta('k', 1);
      await store.clear();
      await store.close(); // idempotent
    });

    test('close on a never-opened store does not open it', () async {
      var opened = false;
      final store = LazyStorageLocalStore(() async {
        opened = true;
        return MemoryStorageLocalStore();
      });
      await store.close();
      expect(opened, isFalse);
    });
  });
}
