import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/src/offline/transfer_queue.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

FileData _data(String path, {required String id}) => FileData(
      id: id,
      directory: path.substring(0, path.lastIndexOf('/')),
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
  late MemoryStorageLocalStore store;
  late OfflineCatalog cat;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('winche-prune');
    store = MemoryStorageLocalStore();
    // NoopApi throws on every call: passing proves pruning never reaches the server.
    cat = OfflineCatalog(api: NoopApi(), store: store, directoryResolver: () async => tmp.path);
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> seed(String path, String id) async {
    final local = '${tmp.path}/$id.png';
    await File(local).writeAsBytes([1, 2, 3]);
    await cat.debugPut(CatalogEntry(
      data: _data(path, id: id),
      localPath: local,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
  }

  test('drops what is not kept, at any depth, and only under the path', () async {
    await seed('u1/themes/t1/logo-a.png', 'a'); // replaced
    await seed('u1/themes/t1/logo-b.png', 'b'); // referenced
    await seed('u1/themes/t2/logo-c.png', 'c'); // its document is gone
    await seed('u1/themesOld/x.png', 'x'); // a neighbour, not under the path
    await seed('u2/themes/t1/logo-a.png', 'y'); // another user's

    final ref = ChildReference(path: 'u1/themes', api: NoopApi(), catalog: cat);
    final dropped = await ref.pruneCache(keep: ['u1/themes/t1/logo-b.png']);

    expect(dropped, ['u1/themes/t1/logo-a.png', 'u1/themes/t2/logo-c.png']);
    expect(await cat.cachedFile('u1/themes/t1/logo-a.png'), isNull);
    expect(File('${tmp.path}/a.png').existsSync(), isFalse);
    expect(await cat.cachedFile('u1/themes/t1/logo-b.png'), isNotNull);
    expect(await cat.cachedFile('u1/themesOld/x.png'), isNotNull);
    expect(await cat.cachedFile('u2/themes/t1/logo-a.png'), isNotNull);
  });

  test('keeps a file whose upload is still queued', () async {
    await seed('u1/themes/t1/logo-new.png', 'n');
    await TransferQueue(store).enqueue((seq) => TransferRecord(
          seq: seq,
          path: 'u1/themes/t1/logo-new.png',
          localPath: '${tmp.path}/n.png',
          mimeType: 'image/png',
          metadata: null,
          multipartThreshold: null,
          status: TransferStatus.pending,
          attempt: 0,
          lastError: null,
          createdAt: DateTime.utc(2026, 1, 1),
        ));
    final ctrl = TransferController(
      api: NoopApi(),
      store: store,
      multipartThreshold: 5 * 1024 * 1024,
      directoryResolver: () async => tmp.path,
      retry: const TransferRetryConfig(pollInterval: Duration(hours: 1)),
    );
    final ref = ChildReference(path: 'u1/themes', api: NoopApi(), catalog: cat, controller: ctrl);

    expect(await ref.pruneCache(keep: const []), isEmpty);
    expect(await cat.cachedFile('u1/themes/t1/logo-new.png'), isNotNull);
    await ctrl.close();
  });

  test('nothing cached: nothing dropped', () async {
    final ref = ChildReference(path: 'u1/themes', api: NoopApi(), catalog: cat);
    expect(await ref.pruneCache(keep: const []), isEmpty);
  });
}
