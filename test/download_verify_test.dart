import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

class _DownloadApi extends NoopApi {
  _DownloadApi(this.recordSize);

  final int recordSize;

  FileData _record() => FileData(
        id: 'rec1',
        directory: 'a',
        path: 'a/b',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: 'image/png',
        sizeBytes: recordSize,
        uploadStatus: UploadStatus.complete,
      );

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async =>
      DownloadSession(
        url: 'https://download.example/x',
        expiresAt: DateTime.utc(2030, 1, 1),
      );

  @override
  Future<FileData?> getFile(String path) async => _record();
}

/// Serves [body] with a Content-Length header of [contentLength].
class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.body, {int? contentLength})
      : contentLength = contentLength ?? body.length;

  final List<int> body;
  final int contentLength;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromBytes(body, 200, headers: {
      Headers.contentLengthHeader: [contentLength.toString()],
    });
  }

  @override
  void close({bool force = false}) {}
}

DownloadTask _start(_DownloadApi api, List<int> body, String saveTo,
    {int? contentLength}) {
  final dio = Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _BytesAdapter(body, contentLength: contentLength);
  return DownloadTask.start(
    reference: ChildReference(path: 'a/b', api: api),
    saveTo: saveTo,
    maxRetries: 0,
    httpClient: dio,
  );
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('winche_dl_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('completes when bytes written match the record size', () async {
    final api = _DownloadApi(5);
    final saveTo = '${dir.path}/out.bin';
    await _start(api, Uint8List(5), saveTo).whenDone;
    expect(File(saveTo).lengthSync(), 5);
  });

  test('fails and deletes the partial file when the download is truncated',
      () async {
    final api = _DownloadApi(5); // server says 5 bytes...
    final saveTo = '${dir.path}/out.bin';
    // ...but only 3 arrive (Content-Length lies / stream cut short).
    final task = _start(api, Uint8List(3), saveTo, contentLength: 3);

    await expectLater(task.whenDone, throwsA(isA<Exception>()));
    expect(File(saveTo).existsSync(), isFalse);
  });
}
