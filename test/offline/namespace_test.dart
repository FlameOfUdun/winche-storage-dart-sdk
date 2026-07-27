import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/local_paths.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Waits for [condition], failing the test rather than hanging if it never
/// holds. Used instead of a fixed sleep for work whose latency is disk-bound.
Future<void> _until(Future<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition never became true within $timeout');
}

void main() {
  group('validateNamespace', () {
    test('accepts what survives as a directory name', () {
      for (final ns in ['user-1', 'a.b_c', 'ABC123', '_', 'u.v-w']) {
        expect(validateNamespace(ns), ns);
      }
    });

    test('rejects anything that could escape or collide', () {
      // Rejected rather than sanitised: rewriting `a/b` to `a_b` would quietly
      // collapse two identities onto one store, which is the leak the scoping
      // exists to prevent.
      for (final ns in ['', '.', '..', 'a/b', r'a\b', 'a b', 'a:b', 'ç']) {
        expect(() => validateNamespace(ns), throwsArgumentError,
            reason: 'accepted "$ns"');
      }
    });
  });

  group('scopedRootPath', () {
    test('puts each identity in its own directory under the parent', () {
      final a = scopedRootPath('/data', 'user-a');
      final b = scopedRootPath('/data', 'user-b');
      expect(p.basename(a), 'winche_storage_user-a');
      expect(p.basename(b), 'winche_storage_user-b');
      expect(a, isNot(b));
      expect(p.dirname(a), p.dirname(b));
    });

    test('cache and staging hang off the scoped root, not off each other', () {
      final root = scopedRootPath('/data', 'u');
      final cached = cacheFilePath(root, 'id', sourceName: 'x.png');
      final staged = stagingFilePath(root, 'a/b.png');

      expect(p.split(cached), containsAllInOrder(['winche_storage_u', 'cache']));
      expect(p.split(staged), containsAllInOrder(['winche_storage_u', 'staging']));
      // Siblings: clearOfflineCache() empties cache/ without touching an upload
      // that is still in flight.
      expect(p.isWithin(p.join(root, 'cache'), staged), isFalse);
    });
  });

  group('config validation', () {
    Uri uri() => Uri.parse('https://x/f');

    test('a persistent store requires a namespace', () {
      expect(() => WincheStorage(WincheStorageConfig(uri: uri())),
          throwsArgumentError);
      expect(
          () => WincheStorage(WincheStorageConfig(
              uri: uri(), directoryResolver: () async => '/tmp')),
          throwsArgumentError);
    });

    test('inMemory rejects a namespace — there is nothing to scope', () {
      expect(
          () => WincheStorage(WincheStorageConfig(
              uri: uri(), inMemory: true, namespaceResolver: () => 'u')),
          throwsArgumentError);
    });

    test('inMemory alone is fine, and so is a namespaced persistent store', () {
      expect(
          WincheStorage(WincheStorageConfig(uri: uri(), inMemory: true)),
          isA<WincheStorage>());
      expect(
          WincheStorage(WincheStorageConfig(
              uri: uri(), namespaceResolver: () => 'u')),
          isA<WincheStorage>());
    });
  });

  group('isolation between identities', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('winche-ns'));
    tearDown(() => tmp.deleteSync(recursive: true));

    // Port 1 is reliably closed, so every request is a deterministic connection
    // error — classified `unavailable`, so the transfer pauses and its record
    // stays queued. A bogus hostname is not equivalent: search-domain or
    // wildcard DNS can resolve it and turn the failure into a 404, which is
    // terminal and drops the record.
    WincheStorage open(String ns) => WincheStorage(WincheStorageConfig(
          uri: Uri.parse('http://127.0.0.1:1/f'),
          namespaceResolver: () => ns,
          directoryResolver: () async => tmp.path,
          retryPollInterval: const Duration(hours: 1),
        ));

    test('one user cannot see the other\'s catalog or transfer queue', () async {
      final a = open('user-a');
      final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
      a.child('shared/x.txt').uploadPath(src.path, enqueue: true);
      // Enqueueing is async — the first sembast open creates a directory — so
      // poll rather than guess a sleep long enough for a cold disk.
      await _until(() async => (await a.pendingTransfers()).isNotEmpty);
      await a.close();

      final b = open('user-b');
      expect(await b.pendingTransfers(), isEmpty,
          reason: "user-b replayed user-a's queued upload");
      expect((await b.child('shared/x.txt').offlineSnapshot()).exists, isFalse,
          reason: "user-b read user-a's cached file");
      await b.close();

      // Re-opening as user-a finds their own work still waiting.
      final again = open('user-a');
      expect(await again.pendingTransfers(), isNotEmpty);
      await again.close();
    });

    test('each identity gets its own directory on disk', () async {
      final a = open('user-a');
      final b = open('user-b');
      // Touch each store so its sembast file is actually created.
      await a.pendingTransfers();
      await b.pendingTransfers();
      await a.close();
      await b.close();

      final dirs = tmp
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toSet();
      expect(dirs, containsAll(['winche_storage_user-a', 'winche_storage_user-b']));
    });

    test('an unusable namespace fails when the store opens', () async {
      final s = WincheStorage(WincheStorageConfig(
        uri: Uri.parse('https://x/f'),
        namespaceResolver: () => '../escape',
        directoryResolver: () async => tmp.path,
        retryPollInterval: const Duration(hours: 1),
      ));
      await expectLater(s.pendingTransfers(), throwsArgumentError);
    });
  });

  test('withStore takes no namespace — the store is already the caller\'s',
      () async {
    final s = WincheStorage.withStore(NoopApi(), MemoryStorageLocalStore());
    expect(await s.pendingTransfers(), isEmpty);
    await s.close();
  });
}
