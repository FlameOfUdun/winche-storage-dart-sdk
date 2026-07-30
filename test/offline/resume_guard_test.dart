import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

FileData _remote({required String hash, int size = 6}) => FileData(
      id: 'id-a_b.png',
      directory: 'a',
      path: 'a/b.png',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: size,
      uploadStatus: UploadStatus.complete,
      contentHash: hash,
    );

class _Api extends NoopApi {
  _Api(this.hash);
  final String hash;

  @override
  Future<FileData?> getFile(String path) async => _remote(hash: hash);

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async =>
      DownloadSession(url: 'https://dl/x', expiresAt: DateTime.utc(2030));
}

/// Captures the request headers and serves the full 6-byte body.
class _CapturingAdapter implements HttpClientAdapter {
  final headers = <String, List<String>>{};

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    options.headers.forEach((k, v) => headers[k] = ['$v']);
    return ResponseBody.fromBytes([9, 9, 9, 9, 9, 9], 200, headers: {
      Headers.contentLengthHeader: ['6'],
      'etag': ['"new-etag"'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-resume'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  });

  /// The state an abrupt process kill leaves behind: a `downloading` row and a
  /// partial file, both describing the content that was current at the time.
  Future<(OfflineCatalog, _CapturingAdapter, String)> interrupted({
    required String rowHash,
    required String serverHash,
  }) async {
    final api = _Api(serverHash);
    final adapter = _CapturingAdapter();
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null))
      ..httpClientAdapter = adapter;
    final catalog = OfflineCatalog(
      api: api,
      store: MemoryStorageLocalStore(),
      directoryResolver: () async => tmp.path,
      httpClient: dio,
    );
    // Mirrors what _cachePath produces for this record.
    final local = '${tmp.path}/cache/id-a_b.png';
    await File(local).parent.create(recursive: true);
    await File(local).writeAsBytes([1, 2, 3]); // stale prefix
    await catalog.debugPut(CatalogEntry(
      data: _remote(hash: rowHash),
      localPath: local,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.downloading,
      etag: '"old-etag"',
    ));
    return (catalog, adapter, local);
  }

  test('a changed contentHash discards the partial instead of appending',
      () async {
    // The bug this guards: appending fresh bytes onto a prefix from different
    // content produces a file that passes a length check and is silently
    // corrupt. Assert on the bytes, not the size — a size check cannot tell an
    // old-prefix/new-suffix splice from the real thing.
    final (catalog, adapter, local) =
        await interrupted(rowHash: 'OLD', serverHash: 'NEW');

    final ref = ChildReference(path: 'a/b.png', api: _Api('NEW'));
    await catalog.refresh(ref);

    expect(File(local).readAsBytesSync(), [9, 9, 9, 9, 9, 9],
        reason: 'the stale prefix survived into the cached file');
    expect(adapter.headers.containsKey('Range'), isFalse,
        reason: 'resumed from a partial the server had invalidated');
  });

  test('an unchanged contentHash resumes with Range and If-Range', () async {
    final (catalog, adapter, _) =
        await interrupted(rowHash: 'SAME', serverHash: 'SAME');

    final ref = ChildReference(path: 'a/b.png', api: _Api('SAME'));
    await catalog.refresh(ref);

    expect(adapter.headers['Range'], ['bytes=3-']);
    // Second layer: even with a matching hash, the server gets the chance to
    // say the object changed by answering 200 instead of 206.
    expect(adapter.headers['If-Range'], ['"old-etag"']);
  });

  test('the ETag from the response is stored for the next resume', () async {
    final (catalog, _, _) =
        await interrupted(rowHash: 'SAME', serverHash: 'SAME');

    final ref = ChildReference(path: 'a/b.png', api: _Api('SAME'));
    await catalog.refresh(ref);

    expect((await catalog.entryFor('a/b.png'))!.etag, '"new-etag"');
  });
}
