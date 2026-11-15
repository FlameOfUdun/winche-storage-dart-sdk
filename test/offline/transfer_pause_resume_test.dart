import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';
import '../support/fake_http.dart';

class _UpApi extends NoopApi {
  FileData? _rec;
  @override
  Future<FileData?> getFile(String path) async => _rec;
  @override
  Future<FileData> setFile(String path, String mime, int size,
          {Map<String, dynamic>? metadata,
      bool ifNotExists = false,
      int? ifVersion,
      String? contentDisposition,
      String? cacheControl}) async =>
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

/// Blocks the PUT on [gate]; signals [reached] once the PUT is in-flight.
class _GatedAdapter {
  final gate = Completer<void>();
  final reached = Completer<void>();
  late final http = fakeHttp((_) async {
    if (!reached.isCompleted) reached.complete();
    await gate.future;
    return respond(const []);
  });
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-pause'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('pausing a tracked upload stops the drive; resume completes it',
      () async {
    final api = _UpApi();
    final adapter = _GatedAdapter();
    final ctrl = TransferController(
      api: api,
      store: MemoryStorageLocalStore(),
      multipartThreshold: 5 * 1024 * 1024,
      directoryResolver: () async => tmp.path,
      httpClient: adapter.http,
      retry: const TransferRetryConfig(pollInterval: Duration(hours: 1)),
    );
    final src = File('${tmp.path}/s.txt')..writeAsBytesSync([1, 2, 3]);

    final task = ctrl.startUpload(
      ChildReference(path: 'a/b', api: api),
      localPath: src.path,
      mimeType: 'text/plain',
      multipartThreshold: 5 * 1024 * 1024,
    );

    // Wait until the PUT is in-flight (deterministic), then pause.
    await adapter.reached.future;
    expect(task.state.status, UploadTaskStatus.running);
    task.pause();

    // The drive loop must NOT hang: the handle settles to paused, whenDone unset.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(task.state.status, UploadTaskStatus.paused);

    // Release the gate so the resumed attempt's PUT can finish, then resume.
    adapter.gate.complete();
    task.resume();
    await task.whenDone; // resolves only because resume re-drove the SAME handle
    expect(task.state.status, UploadTaskStatus.complete);

    await ctrl.close();
  });
}
