import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Returns an updated record with the new metadata AND a *changed* contentHash —
/// simulating that the server content was overwritten by another client between
/// pinning and this metadata edit. The cache must NOT adopt that new hash.
class _MetaApi extends NoopApi {
  @override
  Future<FileData> updateMetadata(
          String path, Map<String, dynamic> metadata) async =>
      FileData(
        id: 'id1',
        directory: 'd',
        path: path,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        metadata: metadata,
        version: 2,
        mimeType: 'image/png',
        sizeBytes: 3,
        uploadStatus: UploadStatus.complete,
        contentHash: 'etag-CHANGED',
      );
}

FileData _data(Map<String, dynamic> metadata, String hash) => FileData(
      id: 'id1',
      directory: 'd',
      path: 'a/b.png',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: metadata,
      version: 1,
      mimeType: 'image/png',
      sizeBytes: 3,
      uploadStatus: UploadStatus.complete,
      contentHash: hash,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-meta-sync'));
  tearDown(() => tmp.deleteSync(recursive: true));

  OfflineCatalog catFor(WincheStorageApi api) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        multipartThreshold: 5 * 1024 * 1024,
      );

  test('updateMetadata syncs cached metadata but preserves the contentHash',
      () async {
    final api = _MetaApi();
    final catalog = catFor(api);
    await catalog.debugPut(CatalogEntry(
      data: _data({'k': 'old'}, 'etag-1'),
      localPath: '${tmp.path}/id1.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: catalog);

    await ref.updateMetadata({'k': 'new'});

    final entry = await catalog.entryFor('a/b.png');
    expect(entry!.data.metadata['k'], 'new'); // metadata synced
    expect(entry.data.contentHash, 'etag-1'); // fingerprint NOT clobbered
    expect(entry.status, CatalogStatus.ready); // local state preserved
    expect(entry.localPath, '${tmp.path}/id1.png');
  });

  test('updateMetadata leaves the cache alone when the file is not pinned',
      () async {
    final api = _MetaApi();
    final catalog = catFor(api);
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: catalog);

    final snap = await ref.updateMetadata({'k': 'new'});

    expect(snap.data!.metadata['k'], 'new'); // server result still returned
    expect(await catalog.entryFor('a/b.png'), isNull); // nothing cached
  });

  test('updateMetadata with no store just returns the server snapshot',
      () async {
    final ref = ChildReference(path: 'a/b.png', api: _MetaApi()); // no catalog

    final snap = await ref.updateMetadata({'k': 'new'});

    expect(snap.data!.metadata['k'], 'new');
  });
}
