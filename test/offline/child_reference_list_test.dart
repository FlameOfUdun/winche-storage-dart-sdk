import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

FileData _data(String path, {String mime = 'image/png'}) => FileData(
      id: 'id-${path.replaceAll('/', '_')}',
      directory:
          path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '',
      path: path,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: mime,
      sizeBytes: 3,
      uploadStatus: UploadStatus.complete,
    );

/// Serves a fixed listing (with optional mimeType filtering).
class _ListApi extends NoopApi {
  _ListApi(this._files);
  final List<FileData> _files;
  @override
  Future<List<FileData>> listDirectory(String directory,
          {String? mimeType}) async =>
      mimeType == null
          ? _files
          : _files.where((d) => d.mimeType == mimeType).toList();
}

/// listDirectory always fails as if the server is unreachable.
class _OfflineListApi extends NoopApi {
  @override
  Future<List<FileData>> listDirectory(String directory,
          {String? mimeType}) async =>
      throw const StorageUnavailableException('offline');
}

/// listDirectory fails with a non-offline error.
class _ErrorListApi extends NoopApi {
  @override
  Future<List<FileData>> listDirectory(String directory,
          {String? mimeType}) async =>
      throw const StorageInternalException('boom');
}

CatalogEntry _entry(String path, String dir, {String mime = 'image/png'}) =>
    CatalogEntry(
      data: _data(path, mime: mime),
      localPath: '$dir/${path.replaceAll('/', '_')}',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-list'));
  tearDown(() => tmp.deleteSync(recursive: true));

  OfflineCatalog catFor(WincheStorageApi api) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        multipartThreshold: 5 * 1024 * 1024,
      );

  test('online: returns fromCache=false with a FileSnapshot per record',
      () async {
    final api = _ListApi([_data('dir/a.png'), _data('dir/b.png')]);
    final ref = ChildReference(path: 'dir', api: api);

    final snap = await ref.list();

    expect(snap.fromCache, isFalse);
    expect(snap.files.map((f) => f.reference.path), ['dir/a.png', 'dir/b.png']);
    expect(snap.length, 2);
    expect(snap.name, 'dir');
  });

  test('online: enriches isCached/localPath from the catalog', () async {
    final api = _ListApi([_data('dir/a.png')]);
    final cat = catFor(api);
    await cat.debugPut(_entry('dir/a.png', tmp.path));
    final ref = ChildReference(path: 'dir', api: api, catalog: cat);

    final snap = await ref.list();

    expect(snap.files.single.data!.isCached, isTrue);
    expect(snap.files.single.data!.localPath, '${tmp.path}/dir_a.png');
  });

  test('offline: returns pinned files directly under the path, fromCache=true',
      () async {
    final api = _OfflineListApi();
    final cat = catFor(api);
    for (final p in ['dir/a.png', 'dir/b.png', 'dir/sub/c.png', 'other/d.png']) {
      await cat.debugPut(_entry(p, tmp.path));
    }
    final ref = ChildReference(path: 'dir', api: api, catalog: cat);

    final snap = await ref.list();

    expect(snap.fromCache, isTrue);
    expect(snap.files.map((f) => f.reference.path).toList()..sort(),
        ['dir/a.png', 'dir/b.png']);
    expect(snap.files.every((f) => f.fromCache), isTrue);
  });

  test('offline: applies the mimeType filter', () async {
    final api = _OfflineListApi();
    final cat = catFor(api);
    await cat.debugPut(_entry('dir/a.png', tmp.path, mime: 'image/png'));
    await cat.debugPut(_entry('dir/b.jpg', tmp.path, mime: 'image/jpeg'));
    final ref = ChildReference(path: 'dir', api: api, catalog: cat);

    final snap = await ref.list(mimeType: 'image/jpeg');

    expect(snap.fromCache, isTrue);
    expect(snap.files.map((f) => f.reference.path), ['dir/b.jpg']);
  });

  test('offline with no catalog rethrows', () async {
    final ref = ChildReference(path: 'dir', api: _OfflineListApi());
    expect(ref.list, throwsA(isA<StorageUnavailableException>()));
  });

  test('non-offline API errors propagate', () async {
    final api = _ErrorListApi();
    final ref = ChildReference(path: 'dir', api: api, catalog: catFor(api));
    expect(ref.list, throwsA(isA<StorageInternalException>()));
  });
}
