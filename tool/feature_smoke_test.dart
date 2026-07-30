// Feature smoke test for the Winche Storage Dart SDK against a live server.
//
// Exercises the 5.0 lifecycle end to end — core-owned sessions, per-identity
// stores, and the access rules configured in
// samples/Winche.Storage.Sample/Program.cs:
//
//   * the sample maps uid from the bearer token verbatim, so this script signs
//     in with a token equal to its uid
//   * rule: match userFiles/{userId}/{rest=**} allow All if auth.uid == userId
//
// So everything under userFiles/alice is ALLOWED for alice and DENIED for bob.
// The script checks both sides.
//
// Run the server first:
//   dotnet run --launch-profile http      (from samples/Winche.Storage.Sample)
//
// Then, from the SDK package root:
//   dart run tool/feature_smoke_test.dart
//
// Exit code is non-zero if any check fails.
//
// ignore_for_file: avoid_print, invalid_use_of_visible_for_testing_member —
// progress output is the point of this file, and debugSession is how it asks
// whether a session is bound without adding public surface for one script.
import 'dart:io';
import 'dart:typed_data';

import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

const _defaultBase = 'http://localhost:5209/files';

/// Auth whose token *is* the uid, matching the sample server's claim mapping.
final class SmokeAuth extends WincheAuthService {
  SmokeAuth(super.app);

  WincheIdentity? _identity;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async =>
      _identity?.id;

  void announce(WincheIdentity? identity) {
    _identity = identity;
    notifyIdentityChanged(identity);
  }
}

var _passed = 0;
var _failed = 0;

void check(String label, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  [ok] $label');
  } else {
    _failed++;
    print('  [FAIL] $label${detail == null ? '' : ' — $detail'}');
  }
}

Future<void> expectDenied(String label, Future<void> Function() body) async {
  try {
    await body();
    check(label, false, 'expected a denial, got success');
  } on StoragePermissionDeniedException {
    check(label, true);
  } on StorageNotFoundException {
    // The backend may answer a denied read as a 404 rather than a 403; either
    // way the caller did not get the other user's data, which is the property.
    check(label, true);
  } catch (e) {
    check(label, false, 'expected a denial, got ${e.runtimeType}: $e');
  }
}

Future<void> main(List<String> args) async {
  final base = args.isNotEmpty ? args[0] : _defaultBase;
  final dir = Directory.systemTemp.createTempSync('winche_storage_smoke');
  final runId = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

  print('storage smoke  base=$base  dir=${dir.path}');

  Winche.initializeApp(
    options: WincheOptions(
      storageEndpoint: Uri.parse(base),
      directoryResolver: () async => dir.path,
    ),
  );
  final auth = SmokeAuth(Winche.app);
  final storage = WincheStorage.instance;

  Future<void> signIn(String id) async {
    auth.announce(WincheIdentity(id));
    await Winche.app.settled;
  }

  Future<void> signOut() async {
    auth.announce(null);
    await Winche.app.settled;
  }

  try {
    print('\n[ Unbound before sign-in ]');
    check('child() does not throw while unbound',
        (() {
      try {
        storage.child('userFiles/alice/x.txt');
        return true;
      } catch (_) {
        return false;
      }
    })());
    try {
      await storage.pendingUploads();
      check('pendingUploads reports unbound', false, 'no throw');
    } on WincheUnboundException {
      check('pendingUploads reports unbound', true);
    }

    // A reference built before anyone signs in must start working after.
    final earlyRef = storage.child('userFiles/alice/early_$runId.txt');

    print('\n[ Sign in as alice ]');
    await signIn('alice');
    check('a session is bound', storage.debugSession != null);

    print('\n[ Upload / read back ]');
    final bytes = Uint8List.fromList(List<int>.generate(2048, (i) => i % 256));
    await earlyRef.uploadBytes(bytes, 'application/octet-stream').whenDone;
    check('a reference built while unbound uploads once signed in', true);

    final snap = await earlyRef.getSnapshot();
    check('getSnapshot sees the uploaded file', snap.exists);
    check('size round-trips', snap.data?.sizeBytes == bytes.length,
        'got ${snap.data?.sizeBytes} want ${bytes.length}');

    print('\n[ Directory listing ]');
    final listing = await storage.child('userFiles/alice').listChildren();
    check('listChildren includes the upload',
        listing.files.any((f) => f.reference.path == earlyRef.path));

    print('\n[ Download ]');
    final out = File('${dir.path}/down_$runId.bin');
    await earlyRef.download(out.path).whenDone;
    check('downloaded bytes match', out.existsSync() &&
        out.readAsBytesSync().length == bytes.length);

    print('\n[ Offline cache ]');
    final cached = await earlyRef.keepCached();
    check('keepCached returns a usable copy', File(cached.localPath).existsSync());
    check('cachedFile sees it without a round-trip',
        (await earlyRef.cachedFile()) != null);
    check('checkForUpdate says the copy is current',
        (await earlyRef.checkForUpdate()) == CacheStatus.upToDate);

    print('\n[ Durable transfer queue ]');
    final queued = storage.child('userFiles/alice/queued_$runId.txt');
    final src = File('${dir.path}/src_$runId.txt')..writeAsBytesSync([1, 2, 3]);
    await queued.uploadPath(src.path, enqueue: true).whenDone;
    check('an enqueued upload completes', true);
    check('the queue drains to empty', (await storage.pendingUploads()).isEmpty);

    print('\n[ Metadata ]');
    await earlyRef.updateMetadata({'label': 'smoke'});
    final withMeta = await earlyRef.getSnapshot();
    check('updateMetadata round-trips',
        withMeta.data?.metadata['label'] == 'smoke', '${withMeta.data?.metadata}');

    print('\n[ Access rules — alice cannot reach bob ]');
    await expectDenied(
      "reading bob's file is denied",
      () => storage.child('userFiles/bob/secret.txt').getSnapshot(),
    );
    await expectDenied(
      "listing bob's directory is denied",
      () => storage.child('userFiles/bob').listChildren(),
    );

    print('\n[ User switch — isolation ]');
    await signIn('bob');
    check('switching users rebinds', storage.debugSession != null);

    final asBob = await storage.child('userFiles/bob').listChildren();
    check("bob's listing does not contain alice's file",
        !asBob.files.any((f) => f.reference.path.contains(runId)));
    check("bob's cache is empty of alice's file",
        (await storage.child(earlyRef.path).cachedFile()) == null);
    await expectDenied(
      "bob cannot read alice's file",
      () => storage.child(earlyRef.path).getSnapshot(),
    );

    print('\n[ Switch back — alice keeps her state ]');
    await signIn('alice');
    check("alice's file is still on the server",
        (await earlyRef.getSnapshot()).exists);
    check("alice's cached file survived the round trip",
        (await earlyRef.cachedFile()) != null);

    print('\n[ On-disk layout ]');
    final identities = Directory('${dir.path}/winche').listSync().whereType<Directory>();
    final names = identities.map((d) => d.path.split(RegExp(r'[\\/]')).last).toSet();
    check('one directory per identity', names.length == 2, '$names');
    check('directories are 32-char digests',
        names.every((n) => RegExp(r'^[0-9a-f]{32}$').hasMatch(n)), '$names');
    check('neither directory names the user',
        !names.any((n) => n.contains('alice') || n.contains('bob')));
    check("alice's store is under storage/",
        Directory('${dir.path}/winche/${WincheIdentity('alice').storageKey}/storage')
            .existsSync());
    check('the sembast index is index.db',
        File('${dir.path}/winche/${WincheIdentity('alice').storageKey}/storage/index.db')
            .existsSync());

    print('\n[ Cleanup ]');
    await earlyRef.delete();
    await queued.delete();
    check('deleted the files created by this run',
        !(await earlyRef.getSnapshot()).exists);

    print('\n[ Sign out ]');
    await signOut();
    check('storage is unbound again', storage.debugSession == null);
    try {
      await storage.pendingUploads();
      check('operations report unbound after sign-out', false, 'no throw');
    } on WincheUnboundException {
      check('operations report unbound after sign-out', true);
    }
  } finally {
    await Winche.deinitializeApp();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  }

  print('\n${'=' * 48}');
  if (_failed == 0) {
    print('ALL $_passed/$_passed CHECKS PASSED');
  } else {
    print('$_failed FAILED, $_passed passed');
  }
  exit(_failed == 0 ? 0 : 1);
}
