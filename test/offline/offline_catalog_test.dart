import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _Api extends NoopApi {
  _Api(this._records);
  final Map<String, FileData?> _records;
  @override
  Future<FileData?> getFile(String path) async => _records[path];
}

FileData _data(String path, {int version = 1, int size = 3}) => FileData(
      id: 'id-${path.replaceAll('/', '_')}',
      directory: 'd',
      path: path,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, version),
      metadata: const {},
      version: version,
      mimeType: 'image/png',
      sizeBytes: size,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-catalog'));
  tearDown(() => tmp.deleteSync(recursive: true));

  OfflineCatalog build(Map<String, FileData?> records) => OfflineCatalog(
        api: _Api(records),
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        multipartThreshold: 5 * 1024 * 1024,
      );

  test('isStale: false when nothing pinned', () async {
    final cat = build({'a/b.png': _data('a/b.png')});
    expect(await cat.isStale('a/b.png'), isFalse);
  });

  test('isStale: true when remote version differs from stored', () async {
    final cat = build({'a/b.png': _data('a/b.png', version: 1)});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', version: 1),
      localPath: '${tmp.path}/id-a_b.png.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.isStale('a/b.png'), isFalse);

    final cat2 = build({'a/b.png': _data('a/b.png', version: 2)});
    await cat2.debugPut(CatalogEntry(
      data: _data('a/b.png', version: 1),
      localPath: '${tmp.path}/id-a_b.png.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat2.isStale('a/b.png'), isTrue);
  });

  test('isStale: true when remote deleted', () async {
    final cat = build({'a/b.png': null});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png'),
      localPath: '${tmp.path}/id-a_b.png.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.isStale('a/b.png'), isTrue);
  });

  test('evict removes local file and entry', () async {
    final cat = build({'a/b.png': _data('a/b.png')});
    final f = File('${tmp.path}/id-a_b.png.png')..writeAsBytesSync([1, 2, 3]);
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png'),
      localPath: f.path,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    await cat.evict('a/b.png');
    expect(f.existsSync(), isFalse);
    expect(await cat.entryFor('a/b.png'), isNull);
  });
}
