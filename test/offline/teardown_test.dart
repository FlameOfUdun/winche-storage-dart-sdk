import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/src/offline/lazy_storage_local_store.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Hangs on the first server call until released, so a test can tear the SDK
/// down with a transfer genuinely in flight.
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
    return DownloadSession(
        url: 'http://127.0.0.1:1/x', expiresAt: DateTime.utc(2030));
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
  late WincheApp app;
  late ScriptedAuthService auth;
  late WincheStorage storage;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('winche-teardown');
    // Port 1 is reliably closed, so every request is a deterministic
    // connection error rather than a DNS-dependent one.
    app = WincheApp(
      'teardown',
      options: WincheOptions(
        storageEndpoint: Uri.parse('http://127.0.0.1:1/f'),
        directoryResolver: () async => tmp.path,
      ),
    );
    auth = ScriptedAuthService(app);
    storage = WincheStorage(app)
      ..config = const WincheStorageConfig(
        retryBaseDelay: Duration(milliseconds: 5),
        retryMaxDelay: Duration(milliseconds: 10),
        retryPollInterval: Duration(hours: 1),
      );
  });

  tearDown(() async {
    await app.dispose();
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // Best effort: the store may still hold a handle on Windows.
      }
    }
  });

  /// Signs in, waiting for the session to bind.
  Future<void> signIn([String id = 'u']) async {
    auth.announce(WincheIdentity(id));
    await app.settled;
  }

  /// Signs out, waiting for teardown to complete. Core awaits the hook, so
  /// this returning means the store is really closed.
  Future<void> signOut() async {
    auth.announce(null);
    await app.settled;
  }

  /// Binds fakes directly, bypassing identity, for tests that need to control
  /// the api.
  void bindFakes(WincheStorageApi api) => storage.debugBindStore(
        api,
        MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
      );

  test('sign-out unbinds, and is idempotent', () async {
    await signIn();
    expect(storage.debugSession, isNotNull);

    await signOut();
    expect(storage.debugSession, isNull);

    // Repeating it must not throw or double-close the store.
    await signOut();
    await signOut();
  });

  test('every entry point reports unbound after sign-out', () async {
    await signIn();
    await signOut();

    expect(storage.resumeUploads, throwsA(isA<WincheUnboundException>()));
    expect(storage.pendingUploads, throwsA(isA<WincheUnboundException>()));
    expect(() => storage.uploadFor('a/b'),
        throwsA(isA<WincheUnboundException>()));
    expect(() => storage.downloadFor('a/b'),
        throwsA(isA<WincheUnboundException>()));
    expect(storage.clearCache, throwsA(isA<WincheUnboundException>()));
  });

  test('the same entry points report unbound before the first sign-in', () {
    // Not a StateError: being signed out is recoverable, and the same facade
    // starts working the moment an identity arrives.
    expect(storage.pendingUploads, throwsA(isA<WincheUnboundException>()));
  });

  group('transferEvents is an observation, not a use', () {
    // The reason this matters is the same one child() is lazy for: the call
    // site is typically a `build` method, where throwing tears down the tree
    // instead of reaching an error branch.
    test('never throws, bound or not', () async {
      expect(() => storage.transferEvents, returnsNormally);

      await signIn();
      expect(() => storage.transferEvents, returnsNormally);

      await signOut();
      expect(() => storage.transferEvents, returnsNormally);
    });

    test('reading it does not count as using the facade', () {
      storage.transferEvents;

      // Still settable: observing whether transfers are happening must not
      // lock the tuning the next session is built from.
      expect(
        () => storage.config = const WincheStorageConfig(inMemory: true),
        returnsNormally,
      );
    });

    test('one subscription spans every session', () async {
      // Attached before anyone signs in, and never re-attached: the controller
      // belongs to the facade rather than to a session. Each `_until` is the
      // assertion -- it fails the test if the events never arrive.
      final events = <TransferEvent>[];
      final subscription = storage.transferEvents.listen(events.add);
      addTearDown(subscription.cancel);

      final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);

      await signIn('first');
      storage
          .child('a/b.txt')
          .uploadPath(src.path, enqueue: true)
          .whenDone
          .ignore();
      await _until(() async => events.any((e) => e.path == 'a/b.txt'));

      await signOut();
      await signIn('second');
      storage
          .child('c/d.txt')
          .uploadPath(src.path, enqueue: true)
          .whenDone
          .ignore();
      await _until(() async => events.any((e) => e.path == 'c/d.txt'));
    });
  });

  test('a facade registered mid-session is bound at construction', () async {
    await signIn();
    await storage.dispose(); // free the slot; one per runtime type per app

    // Registration schedules the catch-up dispatch synchronously, and a fresh
    // facade has nothing to tear down -- so the bind lands before the
    // constructor returns rather than a microtask later. Otherwise a facade
    // first obtained inside a widget build is unbound for that whole frame,
    // however long an identity has been signed in.
    final fresh = WincheStorage(app);
    expect(fresh.debugSession, isNotNull);
  });

  group('child() is lazy', () {
    test('building a reference while unbound does not throw', () {
      // The reason this matters: the call site is often a widget field or a
      // `build` method, where throwing tears down the tree instead of
      // reaching an error branch.
      expect(() => storage.child('a/b'), returnsNormally);
      expect(storage.child('a/b').path, 'a/b');
      expect(storage.child('a').child('b').path, 'a/b');
      expect(storage.child('a/b').parent?.path, 'a');
    });

    test('using an unbound reference rejects rather than throwing', () async {
      final ref = storage.child('a/b');
      await expectLater(
          ref.getSnapshot(), throwsA(isA<WincheUnboundException>()));
    });

    test('a reference built while unbound works once an identity arrives',
        () async {
      final ref = storage.child('a/b');
      await signIn();

      // Resolves through the service, so it picks up the session it never saw
      // at construction. Reaching the api at all is the assertion; the server
      // is unreachable by design, so the call fails as a storage error.
      await expectLater(ref.getSnapshot(), throwsA(isA<WincheStorageException>()));
    });

    test('a reference follows a user switch instead of pinning a session',
        () async {
      await signIn('user-a');
      final ref = storage.child('a/b');
      await signOut();

      // The session it was built under is gone, so it reports unbound rather
      // than quietly operating against a torn-down store.
      await expectLater(
          ref.getSnapshot(), throwsA(isA<WincheUnboundException>()));
    });
  });

  test('tearing down mid-transfer raises no "database is closed"', () async {
    final api = _HangingApi();
    bindFakes(api);
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);

    final task = storage.child('a/b.txt').uploadPath(src.path, enqueue: true);
    task.whenDone.ignore();
    await api.started.future; // genuinely in flight

    // Uncatchable sembast errors surface as unhandled async errors, not as a
    // throw from dispose() — so watch the zone rather than just awaiting.
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await storage.dispose();
      api.release();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }, (e, _) => errors.add(e))!;

    expect(errors, isEmpty, reason: 'teardown raced the store: $errors');
  });

  test('teardown does not wait on the network', () async {
    final api = _HangingApi();
    bindFakes(api);
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
    storage
        .child('a/b.txt')
        .uploadPath(src.path, enqueue: true)
        .whenDone
        .ignore();
    await api.started.future;

    // The request never completes; teardown must still return promptly.
    await storage.dispose().timeout(const Duration(seconds: 2));
    api.release();
  });

  test('a one-shot transfer is cancelled, not left running', () async {
    final api = _HangingApi();
    bindFakes(api);

    final task = storage.child('a/b.txt').download(p.join(tmp.path, 'out.bin'));
    await api.started.future;

    await storage.dispose();
    await expectLater(
        task.whenDone, throwsA(isA<StorageCancelledException>()));
    api.release();
  });

  test('a durable transfer survives a sign-out and resumes on sign-in',
      () async {
    await signIn();
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
    storage
        .child('a/b.txt')
        .uploadPath(src.path, enqueue: true)
        .whenDone
        .ignore();
    await _until(() async => (await storage.pendingUploads()).isNotEmpty);

    await signOut();
    await signIn();

    // Nothing is left marked `running`, which on a new process would mean
    // "someone else is driving this".
    final records = await storage.pendingUploads();
    expect(records, hasLength(1));
    expect(records.single.status, isNot(TransferStatus.running));
    expect(records.single.path, 'a/b.txt');
  });

  test('a scheduled retry does not fire after teardown', () async {
    await signIn();
    final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
    storage
        .child('a/b.txt')
        .uploadPath(src.path, enqueue: true)
        .whenDone
        .ignore();
    await _until(() async => (await storage.pendingUploads()).isNotEmpty);

    final errors = <Object>[];
    await runZonedGuarded(() async {
      await signOut();
      // Comfortably longer than the 5-10 ms backoff: an untracked timer would
      // fire here, into a closed store.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }, (e, _) => errors.add(e))!;

    expect(errors, isEmpty, reason: 'a retry timer outlived teardown: $errors');
  });

  group('LazyStorageLocalStore after close', () {
    test('degrades to no-ops rather than throwing', () async {
      final store =
          LazyStorageLocalStore(() async => MemoryStorageLocalStore());
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
