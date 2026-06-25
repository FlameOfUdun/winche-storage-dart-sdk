import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _PinApi extends NoopApi {
  FileData? _existing;
  FileData _rec(int size, UploadStatus s) => FileData(
        id: 'srv-id',
        directory: 'a',
        path: 'a/b.png',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: 'image/png',
        sizeBytes: size,
        uploadStatus: s,
      );
  @override
  Future<FileData?> getFile(String path) async => _existing;
  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
          {Map<String, dynamic>? metadata}) async =>
      _existing = _rec(sizeBytes, UploadStatus.pending);
  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession(url: 'https://up/whole', expiresAt: DateTime.utc(2030));
  @override
  Future<FileData> confirmUpload(String path) async =>
      _existing!.copyWith(uploadStatus: UploadStatus.complete);
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromBytes(<int>[], 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-ctrl-pin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a pinned upload through the controller finalizes a ready entry',
      () async {
    final api = _PinApi();
    final store = MemoryStorageLocalStore();
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null))
      ..httpClientAdapter = _OkAdapter();
    final ctrl = TransferController(
      api: api,
      store: store,
      multipartThreshold: 5 * 1024 * 1024,
      directoryResolver: () async => tmp.path,
      httpClient: dio,
      retry: const TransferRetryConfig(pollInterval: Duration(hours: 1)),
    );
    final catalog = OfflineCatalog(
      api: api,
      store: store,
      directoryResolver: () async => tmp.path,
      multipartThreshold: 5 * 1024 * 1024,
      controller: ctrl,
    );
    ctrl.pinSink = catalog;

    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);
    final ref = ChildReference(path: 'a/b.png', api: api);

    await ctrl
        .startUpload(ref,
            localPath: src.path,
            mimeType: 'image/png',
            multipartThreshold: 5 * 1024 * 1024,
            pinned: true)
        .whenDone;
    // Let the controller's completion handler run finalize.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final entry = await catalog.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.ready);
    expect(File(entry.localPath).readAsBytesSync(), [1, 2, 3]);
    await ctrl.dispose();
  });
}
