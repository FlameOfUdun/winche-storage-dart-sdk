import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _FlakyApi extends NoopApi {
  bool online = false;
  FileData? _rec;
  @override
  Future<FileData?> getFile(String path) async {
    if (!online) throw const StorageUnavailableException('offline');
    return _rec;
  }

  @override
  Future<FileData> setFile(String path, String mime, int size,
          {Map<String, dynamic>? metadata}) async =>
      _rec = FileData(
        id: 'id', directory: 'd', path: path,
        createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {}, version: 1, mimeType: mime, sizeBytes: size,
        uploadStatus: UploadStatus.pending,
      );
  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession(url: 'https://up/x', expiresAt: DateTime.utc(2030));
  @override
  Future<FileData> confirmUpload(String path) async =>
      _rec!.copyWith(uploadStatus: UploadStatus.complete);
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromBytes(const [], 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-handle'));
  tearDown(() => tmp.deleteSync(recursive: true));

  TransferController build(WincheStorageApi api, StorageLocalStore store) =>
      TransferController(
        api: api, store: store, multipartThreshold: 5 * 1024 * 1024,
        directoryResolver: () async => tmp.path,
        httpClient: Dio(BaseOptions(validateStatus: (s) => s != null))
          ..httpClientAdapter = _OkAdapter(),
        retry: const TransferRetryConfig(
          baseDelay: Duration(milliseconds: 5),
          maxDelay: Duration(milliseconds: 10),
          maxAttempts: 100,
          pollInterval: Duration(hours: 1),
        ),
      );

  test('same handle across offline retries, completes when online', () async {
    final api = _FlakyApi();
    final ctrl = build(api, MemoryStorageLocalStore());
    final src = File('${tmp.path}/s.txt')..writeAsBytesSync([1, 2, 3]);
    final ref = ChildReference(path: 'a/b', api: api);

    final task = ctrl.startUpload(ref,
        localPath: src.path, mimeType: 'text/plain',
        multipartThreshold: 5 * 1024 * 1024);

    expect(identical(ctrl.startUpload(ref,
        localPath: src.path, mimeType: 'text/plain',
        multipartThreshold: 5 * 1024 * 1024), task), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 30));
    // Task should still be retrying (queued between attempts, or running during
    // one); it must NOT have permanently failed or completed yet.
    expect(task.state.status,
        anyOf(UploadTaskStatus.queued, UploadTaskStatus.running));

    api.online = true;
    await task.whenDone;
    expect(task.state.status, UploadTaskStatus.complete);
    await ctrl.dispose();
  });
}
