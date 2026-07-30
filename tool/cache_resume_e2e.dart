/// Live verification of the two cache bugs fixed in 5.0.0, against the real
/// sample server. Neither can be proven with fakes: both are about what
/// survives an abrupt process exit and what the server does in between.
///
///   B1 — a cache fill interrupted by process death could never complete.
///        The row stayed `downloading` forever, so the bytes sat on disk,
///        invisible, and were re-downloaded on every attempt.
///
///   B2 — a resumed download appended to whatever partial was on disk without
///        checking the server's content was unchanged, producing an
///        old-prefix/new-suffix splice that passes a length check.
///
/// Run the sample server first:
///   cd .NET/WincheStorage/samples/Winche.Storage.Sample && dotnet run
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

const _endpoint = 'http://localhost:5209/files';
const _uid = 'alice';

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

/// Announces a fixed identity; the sample server takes the bearer token
/// verbatim as the uid.
final class _Auth extends WincheAuthService {
  _Auth(super.app);
  WincheIdentity? _identity;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async =>
      _identity?.id;

  void signIn(String id) {
    _identity = WincheIdentity(id);
    notifyIdentityChanged(_identity);
  }
}

/// A fresh app over [dir] — the equivalent of relaunching the process against
/// the same on-disk state.
Future<(WincheApp, WincheStorage)> launch(String dir) async {
  final app = WincheApp(
    'resume-e2e-${DateTime.now().microsecondsSinceEpoch}',
    options: WincheOptions(
      storageEndpoint: Uri.parse(_endpoint),
      directoryResolver: () async => dir,
    ),
  );
  final auth = _Auth(app);
  final storage = WincheStorage(app);
  auth.signIn(_uid);
  await app.settled;
  return (app, storage);
}

/// Waits for [condition], failing loudly rather than hanging forever.
Future<bool> until(Future<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return false;
}

/// The cached bytes for [path] under [dir], whatever their state.
File? cacheFileUnder(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) return null;
  final caches = root
      .listSync(recursive: true)
      .whereType<Directory>()
      .where((d) => d.path.replaceAll('\\', '/').endsWith('/storage/cache'));
  for (final c in caches) {
    final files = c.listSync().whereType<File>().toList();
    if (files.isNotEmpty) return files.first;
  }
  return null;
}

Future<void> main() async {
  final tmp = Directory.systemTemp
      .createTempSync('winche-resume-e2e-${DateTime.now().millisecondsSinceEpoch}');
  final runId = DateTime.now().millisecondsSinceEpoch;
  final remotePath = 'userFiles/$_uid/resume_$runId.bin';

  // Large enough that the download is genuinely still in flight when we pull
  // the plug, small enough to stay quick.
  final bigA = Uint8List.fromList(List.filled(6 * 1024 * 1024, 0xAA));
  final bigB = Uint8List.fromList(List.filled(5 * 1024 * 1024, 0xBB));

  try {
    print('\n[ Seed — upload 6 MiB of 0xAA ]');
    {
      final (app, storage) = await launch(tmp.path);
      final src = File('${tmp.path}/src_a.bin')..writeAsBytesSync(bigA);
      await storage.child(remotePath).uploadPath(src.path).whenDone;
      final snap = await storage.child(remotePath).getSnapshot();
      check('uploaded and visible on the server',
          snap.exists && snap.data!.sizeBytes == bigA.length);
      await app.dispose();
    }

    print('\n[ B1 — interrupt a cache fill, then relaunch ]');
    String? partialPath;
    {
      final (app, storage) = await launch(tmp.path);
      // Start the fill and tear the SDK down mid-flight. dispose() aborts the
      // in-flight HTTP without waiting, which is what an app exit looks like.
      storage.child(remotePath).keepCached().ignore();
      final gotPartial = await until(() async {
        final f = cacheFileUnder(tmp.path);
        return f != null && await f.length() > 0;
      });
      check('a partial file exists mid-download', gotPartial);
      partialPath = cacheFileUnder(tmp.path)?.path;
      final partialLen =
          partialPath == null ? 0 : File(partialPath).lengthSync();
      check('the partial is genuinely incomplete',
          partialLen > 0 && partialLen < bigA.length, '$partialLen bytes');
      await app.dispose();
    }

    {
      final (app, storage) = await launch(tmp.path);
      // Pre-fix this returned a snapshot claiming to exist. The bytes are
      // incomplete, so the only honest answer is "I don't have this".
      final beforeRepair = await storage.child(remotePath).cachedFile();
      check('cachedFile is null while the bytes are incomplete',
          beforeRepair == null);

      // Pre-fix the row was stuck `downloading` forever, so this re-downloaded
      // from zero every time and never became usable.
      final repaired = await storage.child(remotePath).keepCached();
      final bytes = File(repaired.localPath).readAsBytesSync();
      check('keepCached completes after the interruption',
          bytes.length == bigA.length, '${bytes.length} bytes');
      check('every byte is the original content',
          bytes.every((b) => b == 0xAA));
      check('cachedFile now returns the copy',
          (await storage.child(remotePath).cachedFile()) != null);
      await app.dispose();
    }

    print('\n[ B2 — interrupt, overwrite server-side, then resume ]');
    {
      // Clear the cache so the next fill starts from nothing.
      final (app0, storage0) = await launch(tmp.path);
      await storage0.child(remotePath).clearCache();
      await app0.dispose();

      final (app, storage) = await launch(tmp.path);
      storage.child(remotePath).keepCached().ignore();
      final gotPartial = await until(() async {
        final f = cacheFileUnder(tmp.path);
        return f != null && await f.length() > 0;
      });
      check('a partial file exists mid-download', gotPartial);
      await app.dispose();
    }

    {
      // Overwrite the remote content. A different size forces the upload path
      // to replace the record rather than skip it, so the contentHash changes.
      final (app, storage) = await launch(tmp.path);
      final src = File('${tmp.path}/src_b.bin')..writeAsBytesSync(bigB);
      await storage.child(remotePath).uploadPath(src.path).whenDone;
      final snap = await storage.child(remotePath).getSnapshot();
      check('the server now holds the new content',
          snap.data!.sizeBytes == bigB.length);
      await app.dispose();
    }

    {
      final (app, storage) = await launch(tmp.path);
      final copy = await storage.child(remotePath).keepCached();
      final bytes = File(copy.localPath).readAsBytesSync();

      // The length check alone would pass on a splice, which is exactly why
      // this corruption was silent. Assert on the bytes.
      check('the cached file is the new length',
          bytes.length == bigB.length, '${bytes.length} bytes');
      final stale = bytes.where((b) => b == 0xAA).length;
      check('no bytes from the old content survived', stale == 0,
          '$stale stale bytes — the partial was appended to');
      check('every byte is the new content', bytes.every((b) => b == 0xBB));
      await app.dispose();
    }

    print('\n[ Cleanup ]');
    {
      final (app, storage) = await launch(tmp.path);
      check('deleted the remote file',
          await storage.child(remotePath).delete());
      await app.dispose();
    }
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  }

  print('\n${'=' * 48}');
  if (_failed == 0) {
    print('ALL $_passed/$_passed CHECKS PASSED');
  } else {
    print('$_failed CHECK(S) FAILED ($_passed passed)');
    exitCode = 1;
  }
}
