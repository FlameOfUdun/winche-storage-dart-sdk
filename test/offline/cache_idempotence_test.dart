import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

FileData _data({UploadStatus status = UploadStatus.complete}) => FileData(
      id: 'id-a_b.png',
      directory: 'a',
      path: 'a/b.png',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: 3,
      uploadStatus: status,
      contentHash: status == UploadStatus.complete ? 'h1' : null,
    );

/// Counts server reads, so a test can prove a call did *not* go to the network.
class _CountingApi extends NoopApi {
  _CountingApi({this.status = UploadStatus.complete});
  final UploadStatus status;
  int getFileCalls = 0;

  @override
  Future<FileData?> getFile(String path) async {
    getFileCalls++;
    return _data(status: status);
  }

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async =>
      DownloadSession(url: 'https://dl/x', expiresAt: DateTime.utc(2030));
}

class _BytesAdapter implements HttpClientAdapter {
  var fetches = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    fetches++;
    return ResponseBody.fromBytes([1, 2, 3], 200,
        headers: {
          Headers.contentLengthHeader: ['3']
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-idem'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  });

  ({OfflineCatalog catalog, _BytesAdapter adapter}) build(_CountingApi api) {
    final adapter = _BytesAdapter();
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null))
      ..httpClientAdapter = adapter;
    return (
      catalog: OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        httpClient: dio,
      ),
      adapter: adapter,
    );
  }

  test('keepCached downloads once, then returns the existing copy', () async {
    // Previously pin() and refresh() were the same function, so caching a file
    // you already had silently re-fetched every byte.
    final api = _CountingApi();
    final (:catalog, :adapter) = build(api);
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: catalog);

    final first = await ref.keepCached();
    expect(adapter.fetches, 1);
    final callsAfterFirst = api.getFileCalls;

    final second = await ref.keepCached();

    expect(adapter.fetches, 1, reason: 're-downloaded an already-cached file');
    expect(second.localPath, first.localPath);
    // The second call is answered entirely from disk — no round-trip at all,
    // not even the preflight.
    expect(api.getFileCalls, callsAfterFirst);
  });

  test('refreshCache always re-downloads', () async {
    final api = _CountingApi();
    final (:catalog, :adapter) = build(api);
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: catalog);

    await ref.keepCached();
    await ref.refreshCache();

    expect(adapter.fetches, 2);
  });

  test('keepCached repairs a row left behind by a process kill', () async {
    // The row says `downloading` and the bytes are absent — nothing else in the
    // system ever heals this, so keepCached has to.
    final api = _CountingApi();
    final (:catalog, :adapter) = build(api);
    await catalog.debugPut(CatalogEntry(
      data: _data(),
      localPath: '${tmp.path}/cache/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.downloading,
    ));
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: catalog);

    expect(await ref.cachedFile(), isNull);

    final repaired = await ref.keepCached();

    expect(adapter.fetches, 1);
    expect(File(repaired.localPath).existsSync(), isTrue);
    expect((await catalog.entryFor('a/b.png'))!.status, CatalogStatus.ready);
    expect(await ref.cachedFile(), isNotNull);
  });

  test('keepCached on a file with no bytes yet is a failed precondition',
      () async {
    final api = _CountingApi(status: UploadStatus.pending);
    final (:catalog, :adapter) = build(api);
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: catalog);

    await expectLater(ref.keepCached(),
        throwsA(isA<StorageFailedPreconditionException>()));
    expect(adapter.fetches, 0, reason: 'tried to download a file with no bytes');
  });

  test('a failed upload reports differently from one still in flight',
      () async {
    // "try later" and "this will never arrive without a re-upload" are
    // different situations; both used to fall through to an obscure
    // signed-URL error.
    final pending = _CountingApi(status: UploadStatus.pending);
    final failed = _CountingApi(status: UploadStatus.failed);

    String messageFrom(Object e) => (e as WincheStorageException).message;

    final pendingErr = await ChildReference(
            path: 'a/b.png', api: pending, catalog: build(pending).catalog)
        .keepCached()
        .then<Object?>((_) => null, onError: (Object e) => e);
    final failedErr = await ChildReference(
            path: 'a/b.png', api: failed, catalog: build(failed).catalog)
        .keepCached()
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(messageFrom(pendingErr!), contains('still uploading'));
    expect(messageFrom(failedErr!), contains('re-uploaded'));
  });
}
