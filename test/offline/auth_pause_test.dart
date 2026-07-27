import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Fails `getFile` — the first server call every upload makes — with whatever
/// [error] currently is, so a test can change the failure mid-flight.
class _FailingApi extends NoopApi {
  _FailingApi(this.error);
  Object? error;
  int calls = 0;

  @override
  Future<FileData?> getFile(String path) async {
    calls++;
    final e = error;
    if (e != null) throw e;
    return null;
  }

  @override
  Future<FileData> setFile(String path, String mime, int size,
          {Map<String, dynamic>? metadata}) =>
      throw const StorageUnavailableException('stop here');
}

Future<void> _until(Future<bool> Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition never became true within $timeout');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-auth'));
  tearDown(() => tmp.deleteSync(recursive: true));

  TransferController build(WincheStorageApi api,
          {int maxAttempts = 2, Duration? base}) =>
      TransferController(
        api: api,
        store: MemoryStorageLocalStore(),
        multipartThreshold: 5 * 1024 * 1024,
        directoryResolver: () async => tmp.path,
        retry: TransferRetryConfig(
          baseDelay: base ?? const Duration(milliseconds: 5),
          maxDelay: const Duration(milliseconds: 10),
          maxAttempts: maxAttempts,
          pollInterval: const Duration(hours: 1), // backstop off unless asked
        ),
      );

  UploadTask start(TransferController ctrl, WincheStorageApi api) {
    final src = File('${tmp.path}/s.txt')..writeAsBytesSync([1, 2, 3]);
    return ctrl.startUpload(ChildReference(path: 'a/b', api: api),
        localPath: src.path,
        mimeType: 'text/plain',
        multipartThreshold: 5 * 1024 * 1024);
  }

  Future<TransferRecord?> only(TransferController c) async {
    final all = await c.pendingTransfers();
    return all.isEmpty ? null : all.single;
  }

  test('an expired token pauses without spending an attempt', () async {
    final api = _FailingApi(const StorageUnauthenticatedException('expired'));
    final ctrl = build(api);
    final events = <TransferEvent>[];
    ctrl.events.listen(events.add);

    start(ctrl, api);
    await _until(() async => (await only(ctrl))?.status == TransferStatus.paused);

    final rec = (await only(ctrl))!;
    expect(rec.status, TransferStatus.paused);
    expect(rec.attempt, 0, reason: 'a pause must not consume the retry budget');
    expect(rec.lastError, contains('expired'));
    expect(events.map((e) => e.type), contains(TransferEventType.paused));

    // Well past maxAttempts worth of probes, the work is still there.
    final before = api.calls;
    await _until(() async => api.calls > before + 3);
    final still = (await only(ctrl))!;
    expect(still.status, TransferStatus.paused);
    expect(still.attempt, 0);

    await ctrl.close();
  });

  test('the paused handle stays alive — whenDone does not settle', () async {
    final api = _FailingApi(const StorageUnauthenticatedException('expired'));
    final ctrl = build(api);
    final task = start(ctrl, api);
    var settled = false;
    unawaited(task.whenDone.then((_) => settled = true,
        onError: (Object _) => settled = true));

    await _until(() async => (await only(ctrl))?.status == TransferStatus.paused);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(settled, isFalse,
        reason: 'a paused transfer is still owed; it must not fail the handle');
    expect(task.state.status,
        anyOf(UploadTaskStatus.queued, UploadTaskStatus.running));

    await ctrl.close();
  });

  test('resumeTransfers re-drives once the token is refreshed', () async {
    final api = _FailingApi(const StorageUnauthenticatedException('expired'));
    // A long base delay parks the probe, so the resume is what moves it.
    final ctrl = build(api, base: const Duration(seconds: 30));
    start(ctrl, api);
    await _until(() async => (await only(ctrl))?.status == TransferStatus.paused);

    final before = api.calls;
    api.error = const StorageUnavailableException('now merely offline');
    await ctrl.resumeTransfers();

    await _until(() async => api.calls > before);
    await ctrl.close();
  });

  test('being offline survives well past the attempt cap', () async {
    final api = _FailingApi(const StorageUnavailableException('offline'));
    final ctrl = build(api, maxAttempts: 2);
    final task = start(ctrl, api);

    // maxAttempts is 2; if `unavailable` counted attempts this would be dropped.
    await _until(() async => api.calls > 6);
    final rec = (await only(ctrl))!;
    expect(rec.status, TransferStatus.paused);
    expect(rec.attempt, 0);
    expect(task.state.status,
        anyOf(UploadTaskStatus.queued, UploadTaskStatus.running));

    await ctrl.close();
  });

  test('permission denied is terminal and its event carries the record',
      () async {
    final api = _FailingApi(const StoragePermissionDeniedException('nope'));
    final ctrl = build(api);
    final events = <TransferEvent>[];
    ctrl.events.listen(events.add);

    final task = start(ctrl, api);
    await expectLater(
        task.whenDone, throwsA(isA<StoragePermissionDeniedException>()));

    expect(await ctrl.pendingTransfers(), isEmpty,
        reason: 'a terminal failure drops the record');

    final failed = events.firstWhere((e) => e.type == TransferEventType.failed);
    expect(failed.record, isNotNull,
        reason: 'the dropped work must be recoverable from the event');
    expect(failed.record!.path, 'a/b');
    expect(failed.record!.localPath, endsWith('s.txt'));
    expect(failed.record!.mimeType, 'text/plain');

    await ctrl.close();
  });

  test('an unrecognised error still exhausts the attempt cap', () async {
    final api = _FailingApi(StateError('something odd'));
    final ctrl = build(api, maxAttempts: 1);
    final task = start(ctrl, api);

    await expectLater(task.whenDone, throwsA(isA<StateError>()));
    final rec = await only(ctrl);
    expect(rec, isNotNull, reason: 'exhausted retries stay visible in the queue');
    expect(rec!.status, TransferStatus.failed);
    expect(rec.attempt, greaterThan(1));

    await ctrl.close();
  });

  test('the backstop poll re-drives a paused transfer unaided', () async {
    final api = _FailingApi(const StorageUnauthenticatedException('expired'));
    final ctrl = TransferController(
      api: api,
      store: MemoryStorageLocalStore(),
      multipartThreshold: 5 * 1024 * 1024,
      directoryResolver: () async => tmp.path,
      retry: const TransferRetryConfig(
        baseDelay: Duration(seconds: 30), // probes parked
        maxDelay: Duration(seconds: 30),
        maxAttempts: 2,
        pollInterval: Duration(milliseconds: 30), // backstop does the work
      ),
    );
    start(ctrl, api);
    await _until(() async => (await only(ctrl))?.status == TransferStatus.paused);

    final before = api.calls;
    await _until(() async => api.calls > before);
    await ctrl.close();
  });
}
