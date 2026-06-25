import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/tasks/upload_task.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _UpApi extends NoopApi {
  _UpApi(this.fail);
  bool fail;
  FileData? _rec;
  @override
  Future<FileData?> getFile(String path) async {
    if (fail) throw const StorageUnavailableException('offline');
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
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-up-managed'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Dio dio() => Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _OkAdapter();
  File src() => File('${tmp.path}/s.txt')..writeAsBytesSync([1, 2, 3]);

  test('managed upload starts queued', () {
    final task = ManagedUploadTask(
      reference: ChildReference(path: 'a/b', api: _UpApi(true)),
      localPath: src().path, mimeType: 'text/plain',
      multipartThreshold: 5 * 1024 * 1024, httpClient: dio(),
    );
    expect(task.state.status, UploadTaskStatus.queued);
  });

  test('runOnce failure -> queued, whenDone not completed', () async {
    final task = ManagedUploadTask(
      reference: ChildReference(path: 'a/b', api: _UpApi(true)),
      localPath: src().path, mimeType: 'text/plain',
      multipartThreshold: 5 * 1024 * 1024, httpClient: dio(),
    );
    await expectLater(task.runOnce(), throwsA(isA<Object>()));
    expect(task.state.status, UploadTaskStatus.queued);
    var done = false;
    unawaited(task.whenDone.then((_) {
      done = true;
    }).catchError((_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(done, isFalse);
  });

  test('runOnce success -> complete with snapshot', () async {
    final task = ManagedUploadTask(
      reference: ChildReference(path: 'a/b', api: _UpApi(false)),
      localPath: src().path, mimeType: 'text/plain',
      multipartThreshold: 5 * 1024 * 1024, httpClient: dio(),
    );
    await task.runOnce();
    expect(task.state.status, UploadTaskStatus.complete);
    final snap = await task.whenDone;
    expect(snap?.data?.uploadStatus, UploadStatus.complete);
  });
}
