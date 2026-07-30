import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/src/offline/local_paths.dart';
import 'package:winche_storage/winche_storage.dart';

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
  // storageKey is a SHA-256 digest of the identity id, so a path segment is
  // always 32 lowercase hex characters. Asserted as a shape rather than a
  // literal: recomputing the digest here would only prove this test agrees
  // with itself, and winche_core already pins the value against an
  // independently computed vector.
  final key = RegExp(r'^[0-9a-f]{32}$');

  group('scopedRootPath', () {
    test('an identity gets a per-package subdirectory of a shared root', () {
      final root = scopedRootPath('/data', WincheIdentity('user-a').storageKey);
      final parts = p.split(root);

      expect(parts[parts.length - 3], 'winche');
      expect(parts[parts.length - 2], matches(key));
      expect(parts.last, 'storage');
    });

    test('the identity never lands on disk in the clear', () {
      // Pre-5.0 the directory was `winche_storage_<uid>`, which wrote the user
      // id into the filesystem and could be collapsed by a case-insensitive
      // one.
      expect(
        scopedRootPath('/data', WincheIdentity('user-a').storageKey),
        isNot(contains('user-a')),
      );
    });

    test('two identities get two directories', () {
      final a = scopedRootPath('/data', WincheIdentity('user-a').storageKey);
      final b = scopedRootPath('/data', WincheIdentity('user-b').storageKey);

      expect(a, isNot(b));
      expect(p.dirname(p.dirname(a)), p.dirname(p.dirname(b)));
    });

    test('ids differing only in case do not collide', () {
      // Used raw these are one directory on NTFS and default macOS APFS, so
      // one user would read the other's cache.
      final upper = scopedRootPath('/d', WincheIdentity('User1').storageKey);
      final lower = scopedRootPath('/d', WincheIdentity('user1').storageKey);

      expect(upper, isNot(lower));
      // The stronger claim: still distinct after the filesystem folds case.
      expect(upper.toLowerCase(), isNot(lower.toLowerCase()));
    });

    test('cache and staging hang off the scoped root, not off each other', () {
      final root = scopedRootPath('/data', WincheIdentity('u').storageKey);
      final cached = cacheFilePath(root, 'id', sourceName: 'x.png');
      final staged = stagingFilePath(root, 'a/b.png');

      expect(p.split(cached), containsAllInOrder(['storage', 'cache']));
      expect(p.split(staged), containsAllInOrder(['storage', 'staging']));
      // Siblings: clearCache() empties cache/ without touching an
      // upload that is still in flight.
      expect(p.isWithin(p.join(root, 'cache'), staged), isFalse);
    });

    test('the web database name carries the same parts, flattened', () {
      // IndexedDB has no directories, so scope/identity/package become a name.
      final identity = WincheIdentity('user-a');

      expect(webDatabaseNameFor(identity),
          'winche_${identity.storageKey}_storage');
      expect(webDatabaseNameFor(identity), isNot(contains('user-a')));
      expect(
        webDatabaseNameFor(WincheIdentity('User1')),
        isNot(webDatabaseNameFor(WincheIdentity('user1'))),
      );
    });
  });

  group('isolation between identities', () {
    late Directory tmp;
    late WincheApp app;
    late ScriptedAuthService auth;
    late WincheStorage storage;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('winche-identity');
      // Port 1 is reliably closed, so every request is a deterministic
      // connection error — classified `unavailable`, so a transfer pauses and
      // its record stays queued. A bogus hostname is not equivalent: search
      // domains or wildcard DNS can resolve it and turn the failure into a
      // 404, which is terminal and drops the record.
      app = WincheApp(
        'identity-scope',
        options: WincheOptions(
          storageEndpoint: Uri.parse('http://127.0.0.1:1/f'),
          directoryResolver: () async => tmp.path,
        ),
      );
      auth = ScriptedAuthService(app);
      storage = WincheStorage(app)
        ..config = const WincheStorageConfig(
          retryPollInterval: Duration(hours: 1),
        );
    });

    tearDown(() async {
      await app.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        // Best effort: the store may still hold a handle on Windows.
      }
    });

    test('one user cannot see the other queued upload or cached file',
        () async {
      auth.announce(WincheIdentity('user-a'));
      await app.settled;

      final src = File(p.join(tmp.path, 's.txt'))..writeAsBytesSync([1, 2, 3]);
      storage.child('shared/x.txt').uploadPath(src.path, enqueue: true);
      // Enqueueing is async — the first sembast open creates a directory — so
      // poll rather than guess a sleep long enough for a cold disk.
      await _until(() async => (await storage.pendingUploads()).isNotEmpty);

      // A user switch, which core sequences: user-a's store is fully closed
      // before user-b's opens.
      auth.announce(WincheIdentity('user-b'));
      await app.settled;

      expect(await storage.pendingUploads(), isEmpty,
          reason: "user-b replayed user-a's queued upload");
      expect(
        await storage.child('shared/x.txt').cachedFile(),
        isNull,
        reason: "user-b read user-a's cached file",
      );

      // Switching back finds user-a's own work still waiting.
      auth.announce(WincheIdentity('user-a'));
      await app.settled;
      expect(await storage.pendingUploads(), isNotEmpty,
          reason: "user-a's queued upload did not survive the switch away");
    });

    test('each identity gets its own directory on disk', () async {
      for (final id in ['user-a', 'user-b']) {
        auth.announce(WincheIdentity(id));
        await app.settled;
        // Touch the store so its sembast file is actually created.
        await storage.pendingUploads();
      }
      auth.announce(null);
      await app.settled;

      final identities = Directory(p.join(tmp.path, 'winche'))
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toSet();

      expect(identities, hasLength(2));
      expect(identities, everyElement(matches(key)));
      expect(identities, contains(WincheIdentity('user-a').storageKey));
      expect(identities, contains(WincheIdentity('user-b').storageKey));
    });
  });
}
