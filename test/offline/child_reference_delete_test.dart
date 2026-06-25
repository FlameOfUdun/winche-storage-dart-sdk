import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/src/offline/transfer_queue.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _DeleteApi extends NoopApi {
  int deletes = 0;
  @override
  Future<bool> deleteFile(String path) async {
    deletes++;
    return true;
  }
}

FileData _data(String path) => FileData(
      id: 'id-${path.replaceAll('/', '_')}',
      directory: 'd',
      path: path,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: 3,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-del'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('delete() evicts the local copy and catalog entry of a pinned file',
      () async {
    final api = _DeleteApi();
    final cat = OfflineCatalog(
      api: api,
      store: MemoryStorageLocalStore(),
      directoryResolver: () async => tmp.path,
      multipartThreshold: 5 * 1024 * 1024,
    );
    final local = File('${tmp.path}/id-a_b.png')..writeAsBytesSync([1, 2, 3]);
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png'),
      localPath: local.path,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));

    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);
    final deleted = await ref.delete();

    expect(deleted, isTrue);
    expect(api.deletes, 1); // server delete still happened
    expect(await cat.entryFor('a/b.png'), isNull); // catalog entry removed
    expect(local.existsSync(), isFalse); // local copy removed
  });

  test('delete() with no catalog just deletes on the server', () async {
    final api = _DeleteApi();
    final ref = ChildReference(path: 'a/b.png', api: api);

    expect(await ref.delete(), isTrue);
    expect(api.deletes, 1);
  });

  test('delete() drops a queued transfer for the path', () async {
    final api = _DeleteApi();
    final store = MemoryStorageLocalStore();
    final q = TransferQueue(store);
    await q.enqueue((seq) => TransferRecord(
          seq: seq,
          kind: TransferKind.download,
          path: 'a/b.png',
          localPath: '${tmp.path}/out',
          mimeType: null,
          metadata: null,
          multipartThreshold: null,
          status: TransferStatus.failed,
          attempt: 0,
          lastError: 'x',
          createdAt: DateTime.utc(2026, 1, 1),
        ));
    final ctrl = TransferController(
      api: api,
      store: store,
      multipartThreshold: 5 * 1024 * 1024,
      directoryResolver: () async => tmp.path,
      retry: const TransferRetryConfig(pollInterval: Duration(hours: 1)),
    );
    final ref = ChildReference(path: 'a/b.png', api: api, controller: ctrl);

    await ref.delete();

    expect((await q.all()).where((r) => r.path == 'a/b.png'), isEmpty);
    await ctrl.dispose();
  });
}
