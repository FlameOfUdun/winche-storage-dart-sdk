import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Inherits [NoopApi], so every method throws [UnimplementedError]. Any test
/// that passes without an override is proof `cachedFiles()` never contacts the
/// server.
class _OfflineApi extends NoopApi {}

FileData _data(String path, {required String id, int sizeBytes = 3}) => FileData(
      id: id,
      directory: path.substring(0, path.lastIndexOf('/')),
      path: path,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: sizeBytes,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-cached-files'));
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

  /// Seeds a catalog row for [path]. [byteCount] bytes are written to disk —
  /// pass null to write none, or a value other than [sizeBytes] for a partial.
  Future<void> seed(
    OfflineCatalog cat,
    String path, {
    required String id,
    int sizeBytes = 3,
    int? byteCount = 3,
    CatalogStatus status = CatalogStatus.ready,
  }) async {
    final local = '${tmp.path}/$id.png';
    if (byteCount != null) {
      await File(local).writeAsBytes(List.filled(byteCount, 1));
    }
    await cat.debugPut(CatalogEntry(
      data: _data(path, id: id, sizeBytes: sizeBytes),
      localPath: local,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: status,
    ));
  }

  test('returns the direct children whose bytes are complete', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png', id: 'a');
    await seed(cat, 'u1/photos/b.png', id: 'b'); // deeper — not a direct child
    await seed(cat, 'u2/c.png', id: 'c'); // another directory
    await seed(cat, 'u1/gone.png', id: 'gone', byteCount: null); // row, no bytes
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    final files = await ref.cachedFiles();

    expect(files.map((f) => f.path), ['u1/a.png']);
    expect(files.single.localPath, '${tmp.path}/a.png');
    expect(files.single.data.id, 'a');
    expect(files.single.cachedAt, DateTime.utc(2026, 1, 1));
  });

  test('is sorted by path', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/c.png', id: 'c');
    await seed(cat, 'u1/a.png', id: 'a');
    await seed(cat, 'u1/b.png', id: 'b');
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect((await ref.cachedFiles()).map((f) => f.path),
        ['u1/a.png', 'u1/b.png', 'u1/c.png']);
  });

  test('is empty when nothing under the path is cached', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u2/c.png', id: 'c');
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect(await ref.cachedFiles(), isEmpty);
  });
}
