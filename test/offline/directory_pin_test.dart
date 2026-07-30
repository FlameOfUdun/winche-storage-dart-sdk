import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Serves a directory whose [children] are the files directly under it. A
/// directory path itself has no file record (`getFile` → null) but would list
/// its children — if anything asked, which is what these tests assert nothing
/// does.
class _DirApi extends NoopApi {
  _DirApi(this.children);
  final List<String> children;

  var listed = false;

  FileData _rec(String path) => FileData(
        id: 'id-${path.replaceAll('/', '_')}',
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

  @override
  Future<FileData?> getFile(String path) async =>
      children.contains(path) ? _rec(path) : null;

  @override
  Future<List<FileData>> listDirectory(String directory,
      {String? mimeType}) async {
    listed = true;
    return [for (final p in children) _rec(p)];
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-dir-pin'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  });

  OfflineCatalog catFor(WincheStorageApi api) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
      );

  test('keepCached on a directory path is not-found, not a bulk pin', () async {
    // Pre-5.0 this pinned every file one level down, so the same call could
    // fetch one file or two hundred depending on a server round-trip the caller
    // could not see. Caching is per file now; bulk is the caller's loop.
    final api = _DirApi(['dir/a.png', 'dir/b.png']);
    final catalog = catFor(api);
    final ref = ChildReference(path: 'dir', api: api, catalog: catalog);

    await expectLater(
        ref.keepCached(), throwsA(isA<StorageNotFoundException>()));

    expect(await catalog.entryFor('dir/a.png'), isNull);
    expect(await catalog.entryFor('dir/b.png'), isNull);
  });

  test('the cache layer never lists a directory', () async {
    // The structural form of the scope boundary: caching deals in file bytes,
    // never in the storage index. If this ever fails, an index dependency has
    // crept back into the cache layer.
    final api = _DirApi(['dir/a.png']);
    final ref = ChildReference(path: 'dir', api: api, catalog: catFor(api));

    try {
      await ref.keepCached();
    } on StorageNotFoundException {
      // expected — the point is what it did *not* do on the way there
    }

    expect(api.listed, isFalse);
  });

  test('keepCached on a genuinely missing path throws not-found', () async {
    // Was StateError, which in Dart means "a bug to fix". A file not being on
    // the server is an ordinary runtime condition.
    final api = _DirApi(const []);
    final ref = ChildReference(path: 'nope', api: api, catalog: catFor(api));

    await expectLater(
        ref.keepCached(), throwsA(isA<StorageNotFoundException>()));
  });
}
