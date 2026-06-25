import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Serves a directory whose [children] are the files directly under it. A
/// directory path itself has no file record (`getFile` → null) but lists its
/// children; any other path is genuinely missing.
class _DirApi extends NoopApi {
  _DirApi(this.children);
  final List<String> children;

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
          {String? mimeType}) async =>
      [for (final p in children) _rec(p)];

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async =>
      DownloadSession(url: 'https://dl/x', expiresAt: DateTime.utc(2030));
}

/// Serves a fixed 3-byte body with a matching Content-Length for every GET.
class _BytesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromBytes([1, 2, 3], 200, headers: {
        Headers.contentLengthHeader: ['3'],
      });
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-dir-pin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  OfflineCatalog catFor(WincheStorageApi api, {Dio? dio}) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        multipartThreshold: 5 * 1024 * 1024,
        httpClient: dio,
      );

  test('makeAvailableOffline on a directory pins every file directly under it',
      () async {
    final api = _DirApi(['dir/a.png', 'dir/b.png']);
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null))
      ..httpClientAdapter = _BytesAdapter();
    final catalog = catFor(api, dio: dio);
    final ref = ChildReference(path: 'dir', api: api, catalog: catalog);

    await ref.makeAvailableOffline();

    final a = await catalog.entryFor('dir/a.png');
    final b = await catalog.entryFor('dir/b.png');
    expect(a!.status, CatalogStatus.ready);
    expect(b!.status, CatalogStatus.ready);
    // The directory path itself is not a catalog entry.
    expect(await catalog.entryFor('dir'), isNull);
  });

  test('makeAvailableOffline on a genuinely missing path throws not-found',
      () async {
    final api = _DirApi(const []); // getFile null AND listDirectory empty
    final catalog = catFor(api);
    final ref = ChildReference(path: 'nope', api: api, catalog: catalog);

    await expectLater(
        ref.makeAvailableOffline(), throwsA(isA<StateError>()));
  });
}
