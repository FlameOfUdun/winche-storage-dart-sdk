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
  test('offline methods throw StateError without a catalog', () {
    final ref = ChildReference(path: 'a/b', api: NoopApi());
    expect(ref.makeAvailableOffline, throwsStateError);
    expect(ref.isStale, throwsStateError);
    expect(ref.evict, throwsStateError);
  });

  test('get() is remote-first and folds localPath/isCached into data when pinned',
      () async {
    final tmp = Directory.systemTemp.createTempSync('winche-cr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final api = _Api({'a/b.png': _data('a/b.png')});
    final cat = OfflineCatalog(
      api: api,
      store: MemoryStorageLocalStore(),
      directoryResolver: () async => tmp.path,
      multipartThreshold: 5 * 1024 * 1024,
    );
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png'),
      localPath: '${tmp.path}/id1.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);
    final snap = await ref.get();
    expect(snap.fromCache, isFalse);
    expect(snap.data!.localPath, '${tmp.path}/id1.png');
    expect(snap.data!.isCached, isTrue);
  });

  test('get() falls back to cache when the server is unreachable', () async {
    final tmp = Directory.systemTemp.createTempSync('winche-cr');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final api = _Api({'a/b.png': _data('a/b.png')}, failGet: true);
    final cat = OfflineCatalog(
      api: api,
      store: MemoryStorageLocalStore(),
      directoryResolver: () async => tmp.path,
      multipartThreshold: 5 * 1024 * 1024,
    );
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png'),
      localPath: '${tmp.path}/id1.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);
    final snap = await ref.get();
    expect(snap.fromCache, isTrue);
    expect(snap.data!.localPath, '${tmp.path}/id1.png');
    expect(snap.data!.isCached, isTrue);
    expect(snap.data!.id, 'id1');
  });

  test('get() rethrows when server is down and nothing is cached', () async {
    final api = _Api({}, failGet: true);
    final cat = OfflineCatalog(
      api: api,
      store: MemoryStorageLocalStore(),
      directoryResolver: () async => '/x',
      multipartThreshold: 5 * 1024 * 1024,
    );
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);
    expect(ref.get, throwsException);
  });
}
