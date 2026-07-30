import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Serves a complete record, then hangs at URL generation so the cache fill is
/// genuinely in flight when the SDK is torn down.
class _HangingFillApi extends NoopApi {
  final _gate = Completer<void>();
  final started = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<FileData?> getFile(String path) async => FileData(
        id: 'id-a_b.png',
        directory: 'a',
        path: 'a/b.png',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: 'image/png',
        sizeBytes: 3,
        uploadStatus: UploadStatus.complete,
        contentHash: 'h1',
      );

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    if (!started.isCompleted) started.complete();
    await _gate.future;
    return DownloadSession(
        url: 'http://127.0.0.1:1/x', expiresAt: DateTime.utc(2030));
  }
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-cache-teardown'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  });

  test('a cache fill in flight is aborted by teardown', () async {
    // Regression: cache fills used to bypass the live registry, because the
    // catalog built its DownloadTask directly. Teardown therefore never saw
    // them, so a fill outlived its session and kept writing to the cache path —
    // and the next session's fill for the same file wrote to the same place
    // concurrently, producing the partial plus a whole second copy.
    //
    // Only reproducible end-to-end (the bytes have to actually land), so this
    // asserts the mechanism instead: the fill is tracked, so it is cancelled.
    final app = WincheApp(
      'cache-teardown',
      options: WincheOptions(
        storageEndpoint: Uri.parse('http://127.0.0.1:1/f'),
        directoryResolver: () async => tmp.path,
      ),
    );
    final api = _HangingFillApi();
    final storage = WincheStorage(app);
    storage.debugBindStore(api, MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path);

    final fill = storage.child('a/b.png').keepCached();
    fill.ignore();
    await api.started.future; // genuinely in flight

    await storage.dispose();
    api.release();

    await expectLater(fill, throwsA(isA<StorageCancelledException>()));
  });
}
