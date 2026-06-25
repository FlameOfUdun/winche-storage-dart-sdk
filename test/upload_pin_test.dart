import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

/// Minimal upload API: getFile->null, setFile->pending, confirm->complete.
/// generateDownloadUrl deliberately throws so a test can assert no download.
class _PinApi extends NoopApi {
  FileData? _existing;
  final List<String> calls = [];

  FileData _rec(int size, String mime, UploadStatus s) => FileData(
        id: 'srv-id',
        directory: 'a',
        path: 'a/b.png',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: mime,
        sizeBytes: size,
        uploadStatus: s,
      );

  @override
  Future<FileData?> getFile(String path) async => _existing;
  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
          {Map<String, dynamic>? metadata}) async =>
      _existing = _rec(sizeBytes, mimeType, UploadStatus.pending);
  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession(url: 'https://up/whole', expiresAt: DateTime.utc(2030));
  @override
  Future<FileData> confirmUpload(String path) async =>
      _existing!.copyWith(uploadStatus: UploadStatus.complete);
  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    calls.add('download');
    throw StateError('no download expected during a pinned upload');
  }
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromBytes(<int>[], 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-pin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Dio okDio() => Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _OkAdapter();

  test('pinned uploadPath stages, uploads from the copy, then finalizes',
      () async {
    final api = _PinApi();
    final ref = ChildReference(path: 'a/b.png', api: api);
    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);

    FileData? finalized;
    var staged = false;
    final task = UploadTask.start(
      reference: ref,
      localPath: src.path,
      mimeType: 'image/png',
      multipartThreshold: 5 * 1024 * 1024,
      httpClient: okDio(),
      stageSource: () async {
        staged = true;
        final dst = '${tmp.path}/staged.bin';
        await File(src.path).copy(dst);
        return dst;
      },
      onPinFinalize: (c) async => finalized = c,
      onPinDeferred: (c) async => fail('should not defer on success'),
    );

    await task.whenDone;
    expect(staged, isTrue);
    expect(finalized!.id, 'srv-id');
    expect(api.calls, isEmpty); // no download issued
  });

  test('staging failure falls back to deferred, upload still succeeds',
      () async {
    final api = _PinApi();
    final ref = ChildReference(path: 'a/b.png', api: api);
    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);

    FileData? deferred;
    final task = UploadTask.start(
      reference: ref,
      localPath: src.path,
      mimeType: 'image/png',
      multipartThreshold: 5 * 1024 * 1024,
      httpClient: okDio(),
      stageSource: () async => throw StateError('disk full'),
      onPinFinalize: (c) async => fail('should not finalize without a stage'),
      onPinDeferred: (c) async => deferred = c,
    );

    final snap = await task.whenDone;
    expect(snap, isNotNull); // upload succeeded
    expect(deferred!.id, 'srv-id');
  });
}
