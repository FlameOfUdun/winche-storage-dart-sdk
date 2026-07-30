import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/src/offline/upload_pin_sink.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _Api extends NoopApi {
  _Api(this._records);
  final Map<String, FileData?> _records;
  @override
  Future<FileData?> getFile(String path) async => _records[path];
}

/// getFile always throws [_error] — models an unreachable server.
class _ThrowingApi extends NoopApi {
  _ThrowingApi(this._error);
  final Object _error;
  @override
  Future<FileData?> getFile(String path) async => throw _error;
}

FileData _data(String path, {int version = 1, int size = 3, String? hash}) =>
    FileData(
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
      contentHash: hash,
    );

File _writeSrc(Directory dir, List<int> bytes) =>
    File('${dir.path}/src-${bytes.length}.bin')..writeAsBytesSync(bytes);

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

  OfflineCatalog buildThrowing(Object error) => OfflineCatalog(
        api: _ThrowingApi(error),
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        multipartThreshold: 5 * 1024 * 1024,
      );

  test('checkForUpdate: unknown when nothing is cached', () async {
    // Nothing to compare against. "Not cached" is cachedFile() == null, which
    // needs no round-trip, so it is not one of this method's answers.
    final cat = build({'a/b.png': _data('a/b.png')});
    expect(await cat.checkForUpdate('a/b.png'), CacheStatus.unknown);
  });

  test('checkForUpdate: upToDate when hashes match', () async {
    final cat = build({'a/b.png': _data('a/b.png', hash: 'h1')});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.checkForUpdate('a/b.png'), CacheStatus.upToDate);
  });

  test('checkForUpdate: contentChanged when remote hash differs', () async {
    final cat = build({'a/b.png': _data('a/b.png', hash: 'h2')});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.checkForUpdate('a/b.png'),
        CacheStatus.contentChanged);
  });

  test('checkForUpdate: remoteDeleted when the server has no record',
      () async {
    final cat = build({'a/b.png': null});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.checkForUpdate('a/b.png'),
        CacheStatus.remoteDeleted);
  });

  test('checkForUpdate: remoteIncomplete when the server holds no bytes',
      () async {
    // A missing contentHash used to fold into `unknown` alongside "could not
    // reach the server", which conflated a definite server answer with the
    // absence of one. uploadStatus states it directly: no bytes yet, because
    // an upload is in flight or one failed.
    final cat = build({
      'a/b.png': FileData(
        id: 'id-a_b.png',
        directory: 'd',
        path: 'a/b.png',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: 'image/png',
        sizeBytes: 3,
        uploadStatus: UploadStatus.pending,
        contentHash: null, // a symptom of pending, not an independent state
      )
    });
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.checkForUpdate('a/b.png'), CacheStatus.remoteIncomplete);
  });

  test('checkForUpdate: unknown when offline', () async {
    final cat = buildThrowing(const StorageUnavailableException('offline'));
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.checkForUpdate('a/b.png'), CacheStatus.unknown);
  });

  test('checkForUpdate: rethrows non-offline API errors', () async {
    final cat = buildThrowing(const StorageInternalException('boom'));
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(() => cat.checkForUpdate('a/b.png'),
        throwsA(isA<StorageInternalException>()));
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

  test('stageForUpload copies a source file into staging/ and verifies size',
      () async {
    final cat = build({});
    final src = File('${tmp.path}/src.bin')..writeAsBytesSync([1, 2, 3, 4]);
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    final staged = await cat.stageForUpload(ref, sourcePath: src.path);

    expect(File(staged).existsSync(), isTrue);
    expect(File(staged).lengthSync(), 4);
    expect(p.split(staged), contains('staging'));
  });

  test('stageForUpload writes in-memory bytes into staging/', () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    final staged =
        await cat.stageForUpload(ref, bytes: Uint8List.fromList([9, 9]));

    expect(File(staged).readAsBytesSync(), [9, 9]);
  });

  test('finalizePin moves the staged file to the id-keyed path, entry ready',
      () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));
    final staged =
        await cat.stageForUpload(ref, bytes: Uint8List.fromList([1, 2, 3]));
    final confirmed = _data('a/b.png'); // id 'id-a_b.png', mime image/png

    await cat.finalizePin(ref, confirmed);

    final expectedFinal = p.join(tmp.path, 'cache', 'id-a_b.png');
    expect(File(staged).existsSync(), isFalse); // moved, not copied
    expect(File(expectedFinal).readAsBytesSync(), [1, 2, 3]);
    final entry = await cat.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.ready);
    expect(entry.localPath, expectedFinal);
  });

  test('finalizePin without a staged file records a stale (deferred) entry',
      () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    await cat.finalizePin(ref, _data('a/b.png')); // nothing staged

    final entry = await cat.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.stale);
  });

  test('markPinDeferred records a stale entry at the id-keyed path', () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    await cat.markPinDeferred(ref, _data('a/b.png'));

    final entry = await cat.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.stale);
    expect(entry.localPath, p.join(tmp.path, 'cache', 'id-a_b.png'));
  });

  test('UploadPinSink: stage, resolve, finalize by path', () async {
    final OfflineCatalog cat = build({});
    final UploadPinSink sink = cat;

    final staged =
        await sink.stageUpload('a/b.png', _writeSrc(tmp, [4, 5]).path);
    expect(await sink.resolveStagedUpload('a/b.png'), staged);

    await sink.finalizeUploadPin('a/b.png', _data('a/b.png'));
    expect(await sink.resolveStagedUpload('a/b.png'), isNull); // moved away
    expect((await cat.entryFor('a/b.png'))!.status, CatalogStatus.ready);
  });
}
