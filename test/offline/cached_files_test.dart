import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

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

  /// A catalog and a reference to [path] on it, over a shared api.
  ///
  /// That api defaults to a bare [NoopApi], whose every method throws — so a
  /// test that passes through this fixture is proof `cachedFiles()` never
  /// reached the server.
  (OfflineCatalog, ChildReference) fixture({
    String path = 'u1',
    WincheStorageApi? api,
  }) {
    final resolved = api ?? NoopApi();
    final cat = catFor(resolved);
    return (cat, ChildReference(path: path, api: resolved, catalog: cat));
  }

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
    final (cat, ref) = fixture();
    await seed(cat, 'u1/a.png', id: 'a');
    await seed(cat, 'u1/photos/b.png', id: 'b'); // deeper — not a direct child
    await seed(cat, 'u2/c.png', id: 'c'); // another directory
    await seed(cat, 'u1/gone.png', id: 'gone', byteCount: null); // row, no bytes

    final files = await ref.cachedFiles();

    expect(files.map((f) => f.path), ['u1/a.png']);
    expect(files.single.localPath, '${tmp.path}/a.png');
    expect(files.single.data.id, 'a');
    expect(files.single.cachedAt, DateTime.utc(2026, 1, 1));
  });

  test('is sorted by path', () async {
    final (cat, ref) = fixture();
    await seed(cat, 'u1/c.png', id: 'c');
    await seed(cat, 'u1/a.png', id: 'a');
    await seed(cat, 'u1/b.png', id: 'b');

    expect((await ref.cachedFiles()).map((f) => f.path),
        ['u1/a.png', 'u1/b.png', 'u1/c.png']);
  });

  test('is empty when nothing under the path is cached', () async {
    final (cat, ref) = fixture();
    await seed(cat, 'u2/c.png', id: 'c');

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('reads a nested directory, not only a top-level one', () async {
    // Every other test queries a single-segment path. Without this, the
    // exclusion of `u1/photos/b.png` above could be passing for the wrong
    // reason — a rule that drops everything below depth 1 would look identical.
    final (cat, ref) = fixture(path: 'u1/photos');
    await seed(cat, 'u1/a.png', id: 'a');
    await seed(cat, 'u1/photos/b.png', id: 'b');

    expect((await ref.cachedFiles()).map((f) => f.path), ['u1/photos/b.png']);
  });

  test('is empty for a path that is itself a cached file', () async {
    // A path is a file or a directory depending on which method you call on
    // it. Exact-parent matching makes this fall out for free — the value is as
    // a guard on the prefix-matching reimplementation that would not.
    final (cat, ref) = fixture(path: 'u1/a.png');
    await seed(cat, 'u1/a.png', id: 'a');

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('skips a row whose bytes are the wrong length', () async {
    // A partial download: the row says ready, the disk disagrees. Disk wins.
    final (cat, ref) = fixture();
    await seed(cat, 'u1/a.png', id: 'a', sizeBytes: 3, byteCount: 2);

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('skips a stale row whose bytes never landed', () async {
    // What markPinDeferred leaves behind when an upload could not be staged.
    final (cat, ref) = fixture();
    await seed(cat, 'u1/a.png',
        id: 'a', byteCount: null, status: CatalogStatus.stale);

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('skips a downloading row that is still partial', () async {
    final (cat, ref) = fixture();
    await seed(cat, 'u1/a.png',
        id: 'a', sizeBytes: 3, byteCount: 1, status: CatalogStatus.downloading);

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('returns a downloading row whose bytes are complete', () async {
    // The process-kill case: the bytes landed, the frame that would have
    // flipped the row to ready died with the process. The bytes decide.
    final (cat, ref) = fixture();
    await seed(cat, 'u1/a.png', id: 'a', status: CatalogStatus.downloading);

    expect((await ref.cachedFiles()).map((f) => f.path), ['u1/a.png']);
  });

  test('throws StateError without a configured store', () {
    expect(ChildReference(path: 'u1', api: NoopApi()).cachedFiles,
        throwsStateError);
  });
}
