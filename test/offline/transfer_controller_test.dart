import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/src/offline/transfer_queue.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Upload API that always fails at record creation, so an UploadTask ends in
/// `failed` quickly without real network I/O. [calls] counts how many times the
/// controller actually drove an attempt.
class _FailingApi extends NoopApi {
  int calls = 0;

  @override
  Future<FileData?> getFile(String path) async => null;

  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
      {Map<String, dynamic>? metadata}) async {
    calls++;
    throw Exception('offline');
  }
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

  test('duplicate startUpload returns the same task and one record', () async {
    final store = MemoryStorageLocalStore();
    final api = _FailingApi();
    final ctrl = build(api, store);
    final ref = ChildReference(path: 'a/b.png', api: api);
    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);

    final t1 = ctrl.startUpload(ref,
        localPath: src.path,
        mimeType: 'image/png',
        multipartThreshold: 5 * 1024 * 1024);
    final t2 = ctrl.startUpload(ref,
        localPath: src.path,
        mimeType: 'image/png',
        multipartThreshold: 5 * 1024 * 1024);
    expect(identical(t1, t2), isTrue);

    await t1.whenDone.catchError((_) => null);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final all = await TransferQueue(store).all();
    expect(all.where((r) => r.path == 'a/b.png').length, 1);
    await ctrl.close();
  });

  test('a failing upload is recorded as failed', () async {
    final store = MemoryStorageLocalStore();
    final api = _FailingApi();
    final ctrl = build(api, store);
    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);

    final task = ctrl.startUpload(
      ChildReference(path: 'a/b.png', api: api),
      localPath: src.path,
      mimeType: 'image/png',
      multipartThreshold: 5 * 1024 * 1024,
    );
    await task.whenDone.catchError((_) => null);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final all = await TransferQueue(store).all();
    expect(all.single.path, 'a/b.png');
    expect(all.single.status, TransferStatus.failed);
    await ctrl.close();
  });

  test('removePath drops persisted transfer records for that path', () async {
    final store = MemoryStorageLocalStore();
    final q = TransferQueue(store);
    TransferRecord rec(int seq, String path) => TransferRecord(
          seq: seq,
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
    await ctrl.close();
  });

  test('pendingUploads returns the queue', () async {
    final store = MemoryStorageLocalStore();
    final q = TransferQueue(store);
    TransferRecord rec(int seq, String path) => TransferRecord(
          seq: seq,
          path: path,
          localPath: '${tmp.path}/$path',
          mimeType: null,
          metadata: null,
          multipartThreshold: null,
          status: TransferStatus.failed,
          attempt: 0,
          lastError: null,
          createdAt: DateTime.utc(2026, 1, 1),
        );
    await q.enqueue((seq) => rec(seq, 'up.png'));
    await q.enqueue((seq) => rec(seq, 'other.png'));

    final ctrl = build(_FailingApi(), store);

    // No `kind` filter: the queue holds uploads and nothing else.
    expect((await ctrl.pendingUploads()).map((r) => r.path).toSet(),
        {'up.png', 'other.png'});
    await ctrl.close();
  });

  test('a download row from an older version is purged, never driven',
      () async {
    // Under the upload-only record shape this row would deserialize into an
    // upload whose localPath is the *download destination* — and driving it
    // would upload a partially fetched file over the server's copy.
    final store = MemoryStorageLocalStore();
    await store.putTransfer(1, {
      'seq': 1,
      'kind': 'download', // the field records no longer carry
      'path': 'a/b.png',
      'localPath': '${tmp.path}/out.png',
      'mimeType': null,
      'metadata': null,
      'multipartThreshold': null,
      'status': 'pending',
      'attempt': 0,
      'lastError': null,
      'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      'pinned': false,
    });

    final api = _FailingApi();
    final ctrl = build(api, store);
    await ctrl.rehydrate();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await ctrl.pendingUploads(), isEmpty);
    expect(await store.allTransfers(), isEmpty, reason: 'row was not purged');
    expect(api.calls, 0, reason: 'the legacy download row was driven');
    await ctrl.close();
  });

  test('rehydrate restarts persisted records', () async {
    final store = MemoryStorageLocalStore();
    final api = _FailingApi();
    final q = TransferQueue(store);
    // The record's localPath is an upload *source* now, so it has to exist:
    // without it the task fails reading the file and never reaches the API,
    // which would make this pass for the wrong reason.
    final src = File('${tmp.path}/out.png')..writeAsBytesSync([1, 2, 3]);
    await q.enqueue((seq) => TransferRecord(
          seq: seq,
          path: 'a/b.png',
          localPath: src.path,
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
    await ctrl.close();
  });
}
