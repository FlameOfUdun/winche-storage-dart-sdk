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

  group('listChildren', () {
    test('returns a FileSnapshot per server record', () async {
      final api = _ListApi([_data('dir/a.png'), _data('dir/b.png')]);
      final ref = ChildReference(path: 'dir', api: api);

      final snap = await ref.listChildren();

      expect(
          snap.files.map((f) => f.reference.path), ['dir/a.png', 'dir/b.png']);
      expect(snap.length, 2);
      expect(snap.name, 'dir');
    });

    test('annotates each file with this device cache state', () async {
      // Replaces the old pattern of calling listChildren() *and*
      // offlineChildren() and hand-building a Set of paths to cross-reference.
      final api = _ListApi([_data('dir/a.png'), _data('dir/b.png')]);
      final cat = catFor(api);
      await cat.debugPut(_entry('dir/a.png', tmp.path));
      final ref = ChildReference(path: 'dir', api: api, catalog: cat);

      final snap = await ref.listChildren();
      final byPath = {for (final f in snap.files) f.reference.path: f};

      expect(byPath['dir/a.png']!.isCached, isTrue);
      expect(byPath['dir/a.png']!.localPath, isNotNull);
      expect(byPath['dir/b.png']!.isCached, isFalse);
      expect(byPath['dir/b.png']!.localPath, isNull);
    });

    test('a row that is not ready does not count as cached', () async {
      final api = _ListApi([_data('dir/a.png')]);
      final cat = catFor(api);
      await cat.debugPut(CatalogEntry(
        data: _data('dir/a.png'),
        localPath: '${tmp.path}/dir_a.png',
        pinnedAt: DateTime.utc(2026, 1, 1),
        status: CatalogStatus.downloading,
      ));
      final ref = ChildReference(path: 'dir', api: api, catalog: cat);

      final snap = await ref.listChildren();

      expect(snap.files.single.isCached, isFalse);
    });

    test('works with no catalog at all', () async {
      final api = _ListApi([_data('dir/a.png')]);
      final ref = ChildReference(path: 'dir', api: api);

      final snap = await ref.listChildren();

      expect(snap.files.single.isCached, isFalse);
    });

    test('throws offline even with a catalog', () async {
      // Listings are never cached: there is no offline branch to fall back to.
      final api = _OfflineListApi();
      final cat = catFor(api);
      await cat.debugPut(_entry('dir/a.png', tmp.path));
      final ref = ChildReference(path: 'dir', api: api, catalog: cat);

      expect(ref.listChildren, throwsA(isA<StorageUnavailableException>()));
    });

    test('throws offline with no catalog', () async {
      final ref = ChildReference(path: 'dir', api: _OfflineListApi());
      expect(ref.listChildren, throwsA(isA<StorageUnavailableException>()));
    });

    test('non-offline API errors propagate', () async {
      final api = _ErrorListApi();
      final ref = ChildReference(path: 'dir', api: api, catalog: catFor(api));
      expect(ref.listChildren, throwsA(isA<StorageInternalException>()));
    });

    test('the mimeType filter is passed to the server', () async {
      final api = _ListApi([
        _data('dir/a.png', mime: 'image/png'),
        _data('dir/b.jpg', mime: 'image/jpeg'),
      ]);
      final ref = ChildReference(path: 'dir', api: api);

      final snap = await ref.listChildren(mimeType: 'image/jpeg');

      expect(snap.files.map((f) => f.reference.path), ['dir/b.jpg']);
    });
  });
}
