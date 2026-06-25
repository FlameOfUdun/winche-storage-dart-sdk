import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _Api extends NoopApi {
  _Api(this.records, {this.failGet = false});
  final Map<String, FileData?> records;
  bool failGet;
  @override
  Future<FileData?> getFile(String path) async {
    if (failGet) throw Exception('offline');
    return records[path];
  }
}

FileData _data(String path) => FileData(
      id: 'id1',
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
  OfflineCatalog catFor(WincheStorageApi api, String dir) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => dir,
        multipartThreshold: 5 * 1024 * 1024,
      );

  CatalogEntry pinned(String dir) => CatalogEntry(
        data: _data('a/b.png'),
        localPath: '$dir/id1.png',
        pinnedAt: DateTime.utc(2026, 1, 1),
        status: CatalogStatus.ready,
      );

  test('offline methods throw StateError without a catalog', () {
    final ref = ChildReference(path: 'a/b', api: NoopApi());
    expect(ref.makeAvailableOffline, throwsStateError);
    expect(ref.offlineCopyStatus, throwsStateError);
    expect(ref.removeOfflineCopy, throwsStateError);
    expect(ref.offlineSnapshot, throwsStateError);
    expect(ref.offlineChildren, throwsStateError);
  });

  test('getSnapshot is server-only: no cache enrichment even when pinned',
      () async {
    final tmp = Directory.systemTemp.createTempSync('winche-cr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final api = _Api({'a/b.png': _data('a/b.png')});
    final cat = catFor(api, tmp.path);
    await cat.debugPut(pinned(tmp.path));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    final snap = await ref.getSnapshot();

    expect(snap.fromCache, isFalse);
    expect(snap.data!.localPath, isNull);
    expect(snap.data!.isCached, isFalse);
  });

  test('getSnapshot throws when the server is unreachable (no fallback)',
      () async {
    final tmp = Directory.systemTemp.createTempSync('winche-cr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final api = _Api({'a/b.png': _data('a/b.png')}, failGet: true);
    final cat = catFor(api, tmp.path);
    await cat.debugPut(pinned(tmp.path)); // pinned, but no fallback
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    expect(ref.getSnapshot, throwsException);
  });

  test('offlineSnapshot returns the cached record without hitting the server',
      () async {
    final tmp = Directory.systemTemp.createTempSync('winche-cr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final api = _Api({}, failGet: true); // server would throw if contacted
    final cat = catFor(api, tmp.path);
    await cat.debugPut(pinned(tmp.path));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    final snap = await ref.offlineSnapshot();

    expect(snap.fromCache, isTrue);
    expect(snap.data!.localPath, '${tmp.path}/id1.png');
    expect(snap.data!.isCached, isTrue);
    expect(snap.data!.id, 'id1');
  });

  test('offlineSnapshot returns a missing snapshot when not pinned', () async {
    final tmp = Directory.systemTemp.createTempSync('winche-cr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final api = _Api({}, failGet: true);
    final cat = catFor(api, tmp.path);
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    final snap = await ref.offlineSnapshot();

    expect(snap.data, isNull);
  });
}
