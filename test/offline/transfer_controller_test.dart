import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/src/offline/transfer_queue.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Download API that always fails at URL generation, so the DownloadTask ends
/// in `failed` quickly without real network I/O.
class _FailingApi extends NoopApi {
  int calls = 0;
  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    calls++;
    throw Exception('offline');
  }

  @override
  Future<FileData?> getFile(String path) async => null;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-ctrl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  TransferController build(WincheStorageApi api, MemoryStorageLocalStore store) =>
      TransferController(
        api: api,
        store: store,
        multipartThreshold: 5 * 1024 * 1024,
        directoryResolver: () async => tmp.path,
        retry: const TransferRetryConfig(
          baseDelay: Duration(milliseconds: 1),
          maxDelay: Duration(milliseconds: 5),
          maxAttempts: 1,
          pollInterval: Duration(hours: 1), // disable the backstop in tests
        ),
      );

  test('duplicate startDownload returns the same task and one record', () async {
    final store = MemoryStorageLocalStore();
    final api = _FailingApi();
    final ctrl = build(api, store);
    final ref = ChildReference(path: 'a/b.png', api: api);

    final t1 = ctrl.startDownload(ref, saveTo: '${tmp.path}/out.png');
    final t2 = ctrl.startDownload(ref, saveTo: '${tmp.path}/out.png');
    expect(identical(t1, t2), isTrue);

    await t1.whenDone.catchError((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final all = await TransferQueue(store).all();
    expect(all.where((r) => r.path == 'a/b.png').length, 1);
    await ctrl.dispose();
  });

  test('a failing download is recorded as failed', () async {
    final store = MemoryStorageLocalStore();
    final api = _FailingApi();
    final ctrl = build(api, store);

    final task = ctrl.startDownload(
      ChildReference(path: 'a/b.png', api: api),
      saveTo: '${tmp.path}/out.png',
    );
    await task.whenDone.catchError((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final q = TransferQueue(store);
    final all = await q.all();
    expect(all.single.kind, TransferKind.download);
    expect(all.single.status, TransferStatus.failed);
    await ctrl.dispose();
  });

  test('removePath drops persisted transfer records for that path', () async {
    final store = MemoryStorageLocalStore();
    final q = TransferQueue(store);
    TransferRecord rec(int seq, String path) => TransferRecord(
          seq: seq,
          kind: TransferKind.download,
          path: path,
          localPath: '${tmp.path}/out',
          mimeType: null,
          metadata: null,
          multipartThreshold: null,
          status: TransferStatus.failed,
          attempt: 0,
          lastError: 'x',
          createdAt: DateTime.utc(2026, 1, 1),
        );
    await q.enqueue((seq) => rec(seq, 'a/b.png'));
    await q.enqueue((seq) => rec(seq, 'other.png'));

    final ctrl = build(_FailingApi(), store);
    await ctrl.removePath('a/b.png');

    final all = await q.all();
    expect(all.map((r) => r.path), ['other.png']);
    await ctrl.dispose();
  });

  test('rehydrate restarts persisted records', () async {
    final store = MemoryStorageLocalStore();
    final api = _FailingApi();
    final q = TransferQueue(store);
    await q.enqueue((seq) => TransferRecord(
          seq: seq,
          kind: TransferKind.download,
          path: 'a/b.png',
          localPath: '${tmp.path}/out.png',
          mimeType: null,
          metadata: null,
          multipartThreshold: null,
          status: TransferStatus.failed,
          attempt: 0,
          lastError: 'prev',
          createdAt: DateTime.utc(2026, 1, 1),
        ));

    final ctrl = build(api, store);
    await ctrl.rehydrate();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(api.calls, greaterThan(0));
    await ctrl.dispose();
  });
}
