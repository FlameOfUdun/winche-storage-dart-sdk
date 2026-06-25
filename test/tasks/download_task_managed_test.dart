import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';
import 'package:winche_storage/src/tasks/download_task.dart';

import '../support/noop_api.dart';

class _DlApi extends NoopApi {
  _DlApi(this.fail);
  bool fail;
  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    if (fail) throw const StorageUnavailableException('offline');
    return DownloadSession(url: 'https://dl/x', expiresAt: DateTime.utc(2030));
  }

  @override
  Future<FileData?> getFile(String path) async => FileData(
        id: 'id', directory: 'd', path: path,
        createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {}, version: 1, mimeType: 'text/plain',
        sizeBytes: 3, uploadStatus: UploadStatus.complete,
      );
}

class _BytesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromBytes([1, 2, 3], 200,
          headers: {Headers.contentLengthHeader: ['3']});
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-dl-managed'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Dio dio() => Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _BytesAdapter();

  test('managed task starts queued and does not auto-run', () async {
    final task = ManagedDownloadTask(
      reference: ChildReference(path: 'a/b', api: _DlApi(true)),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    expect(task.state.status, DownloadTaskStatus.queued);
  });

  test('runOnce: failure returns to queued without completing whenDone',
      () async {
    final task = ManagedDownloadTask(
      reference: ChildReference(path: 'a/b', api: _DlApi(true)),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    await expectLater(task.runOnce(), throwsA(isA<Object>()));
    expect(task.state.status, DownloadTaskStatus.queued);
    var done = false;
    unawaited(task.whenDone.then((_) {
      done = true;
    }).catchError((_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(done, isFalse);
  });

  test('runOnce: success completes the task', () async {
    final api = _DlApi(false);
    final task = ManagedDownloadTask(
      reference: ChildReference(path: 'a/b', api: api),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    await task.runOnce();
    expect(task.state.status, DownloadTaskStatus.complete);
    await task.whenDone;
    expect(File('${tmp.path}/out').readAsBytesSync(), [1, 2, 3]);
  });

  test('failPermanently sets failed and errors whenDone', () async {
    final task = ManagedDownloadTask(
      reference: ChildReference(path: 'a/b', api: _DlApi(true)),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    task.failPermanently(StateError('exhausted'));
    expect(task.state.status, DownloadTaskStatus.failed);
    await expectLater(task.whenDone, throwsA(isA<StateError>()));
  });
}
