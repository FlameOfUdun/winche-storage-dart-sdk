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
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-cr'));
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

  /// A ready row *with the bytes actually on disk* — `cachedFile()` verifies
  /// against the filesystem, so a row alone is not enough.
  Future<CatalogEntry> cached() async {
    final local = '${tmp.path}/id1.png';
    await File(local).writeAsBytes([1, 2, 3]);
    return CatalogEntry(
      data: _data('a/b.png'),
      localPath: local,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    );
  }

  test('cache methods throw StateError without a catalog', () {
    final ref = ChildReference(path: 'a/b', api: NoopApi());
    expect(ref.keepCached, throwsStateError);
    expect(ref.refreshCache, throwsStateError);
    expect(ref.checkForUpdate, throwsStateError);
    expect(ref.clearCache, throwsStateError);
    expect(ref.cachedFile, throwsStateError);
  });

  test('getSnapshot is a server read, annotated with local cache state',
      () async {
    // The metadata is always the server's — there is no metadata cache. What
    // the catalog contributes is whether this device has the bytes.
    final api = _Api({'a/b.png': _data('a/b.png')});
    final cat = catFor(api);
    await cat.debugPut(await cached());
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    final snap = await ref.getSnapshot();

    expect(snap.exists, isTrue);
    expect(snap.isCached, isTrue);
    expect(snap.localPath, '${tmp.path}/id1.png');
  });

  test('getSnapshot throws when the server is unreachable (no fallback)',
      () async {
    final api = _Api({'a/b.png': _data('a/b.png')}, failGet: true);
    final cat = catFor(api);
    await cat.debugPut(await cached()); // cached, but metadata has no fallback
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    expect(ref.getSnapshot, throwsException);
  });

  test('cachedFile returns the local copy without hitting the server',
      () async {
    final api = _Api({}, failGet: true); // server would throw if contacted
    final cat = catFor(api);
    await cat.debugPut(await cached());
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    final copy = await ref.cachedFile();

    expect(copy, isNotNull);
    expect(copy!.localPath, '${tmp.path}/id1.png');
    expect(copy.data.id, 'id1');
    expect(copy.path, 'a/b.png');
  });

  test('cachedFile returns null when not cached', () async {
    // Null, not a "missing snapshot": "I do not have these bytes" and "this
    // file does not exist" are different answers and used to look identical.
    final api = _Api({}, failGet: true);
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: catFor(api));

    expect(await ref.cachedFile(), isNull);
  });

  test('cachedFile returns null when the row exists but the bytes do not',
      () async {
    // Exactly the state a process kill mid-download leaves behind. Trusting the
    // row here would hand back a localPath that cannot be opened.
    final api = _Api({}, failGet: true);
    final cat = catFor(api);
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png'),
      localPath: '${tmp.path}/missing.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    expect(await ref.cachedFile(), isNull);
  });

  test('cachedFile returns null when the bytes are the wrong length', () async {
    // A partial download: the row says ready, the disk disagrees. The disk wins.
    final api = _Api({}, failGet: true);
    final cat = catFor(api);
    final local = '${tmp.path}/partial.png';
    await File(local).writeAsBytes([1, 2]); // expected 3
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png'),
      localPath: local,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat);

    expect(await ref.cachedFile(), isNull);
  });
}
