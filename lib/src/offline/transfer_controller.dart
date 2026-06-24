import 'dart:async';

import 'package:dio/dio.dart';

import '../api/winche_storage_api.dart';
import '../child_reference.dart';
import '../tasks/download_task.dart';
import '../tasks/upload_task.dart';
import 'storage_local_store.dart';
import 'transfer_event.dart';
import 'transfer_queue.dart';
import 'transfer_record.dart';

export 'transfer_event.dart' show TransferRetryConfig;

/// Persists in-flight transfers and resumes them after restarts / failures,
/// driving the existing [UploadTask]/[DownloadTask] engine. The controller is
/// the sole retry authority: tasks are created with `maxRetries: 0` (attempt
/// once) and the controller schedules durable backoff retries itself.
class TransferController {
  TransferController({
    required WincheStorageApi api,
    required StorageLocalStore store,
    required int multipartThreshold,
    Future<String> Function()? directoryResolver,
    TransferRetryConfig retry = const TransferRetryConfig(),
    Dio? httpClient,
  })  : _api = api,
        _queue = TransferQueue(store),
        _multipartThreshold = multipartThreshold,
        _directoryResolver = directoryResolver,
        _retry = retry,
        _httpClient = httpClient {
    _poll = Timer.periodic(_retry.pollInterval, (_) => retryFailed());
  }

  final WincheStorageApi _api;
  final TransferQueue _queue;
  final int _multipartThreshold;
  final Future<String> Function()? _directoryResolver;
  final TransferRetryConfig _retry;
  final Dio? _httpClient;

  final _events = StreamController<TransferEvent>.broadcast();
  final Set<int> _running = {};

  /// Live tasks keyed by path — de-dups concurrent starts for the same path.
  final Map<String, DownloadTask> _activeDownloads = {};
  final Map<String, UploadTask> _activeUploads = {};

  Timer? _poll;
  bool _disposed = false;

  Stream<TransferEvent> get events => _events.stream;

  ChildReference _ref(String path) => ChildReference(
        path: path,
        api: _api,
        multipartThreshold: _multipartThreshold,
        directoryResolver: _directoryResolver,
      );

  DownloadTask startDownload(ChildReference ref, {required String saveTo}) {
    final existing = _activeDownloads[ref.path];
    if (existing != null) return existing;
    final task = DownloadTask.start(
      reference: ref,
      saveTo: saveTo,
      maxRetries: 0,
      httpClient: _httpClient,
    );
    _activeDownloads[ref.path] = task;
    unawaited(_registerDownload(ref.path, task));
    return task;
  }

  UploadTask startUpload(
    ChildReference ref, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
  }) {
    final existing = _activeUploads[ref.path];
    if (existing != null) return existing;
    final task = UploadTask.start(
      reference: ref,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      maxRetries: 0,
      httpClient: _httpClient,
    );
    _activeUploads[ref.path] = task;
    unawaited(_registerUpload(
      ref.path,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      done: task.whenDone,
    ));
    return task;
  }

  Future<void> _registerDownload(String path, DownloadTask task) async {
    final resolved = task.saveTo;
    final seq = await _existingSeq(TransferKind.download, path,
            localPath: resolved) ??
        await _queue.enqueue((seq) => TransferRecord(
              seq: seq,
              kind: TransferKind.download,
              path: path,
              localPath: resolved,
              mimeType: null,
              metadata: null,
              multipartThreshold: null,
              status: TransferStatus.running,
              attempt: 0,
              lastError: null,
              createdAt: DateTime.now(),
            ));
    _running.add(seq);
    _emit(TransferEventType.started, TransferKind.download, path);
    _drive(seq, task.whenDone, TransferKind.download, path);
  }

  Future<void> _registerUpload(
    String path, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    required Future<Object?> done,
  }) async {
    final seq =
        await _existingSeq(TransferKind.upload, path, localPath: localPath) ??
            await _queue.enqueue((seq) => TransferRecord(
                  seq: seq,
                  kind: TransferKind.upload,
                  path: path,
                  localPath: localPath,
                  mimeType: mimeType,
                  metadata: metadata,
                  multipartThreshold: multipartThreshold,
                  status: TransferStatus.running,
                  attempt: 0,
                  lastError: null,
                  createdAt: DateTime.now(),
                ));
    _running.add(seq);
    _emit(TransferEventType.started, TransferKind.upload, path);
    _drive(seq, done, TransferKind.upload, path);
  }

  /// Reuses the seq of an existing record for (kind, path), resetting it to
  /// running. Returns null when no such record exists (caller enqueues fresh).
  Future<int?> _existingSeq(TransferKind kind, String path,
      {String? localPath}) async {
    for (final rec in await _queue.all()) {
      if (rec.kind == kind && rec.path == path) {
        await _queue.update(rec.copyWith(
            status: TransferStatus.running,
            attempt: 0,
            localPath: localPath ?? rec.localPath));
        return rec.seq;
      }
    }
    return null;
  }

  void _removeActive(TransferKind kind, String path) {
    if (kind == TransferKind.download) {
      _activeDownloads.remove(path);
    } else {
      _activeUploads.remove(path);
    }
  }

  /// Wires a task's completion to the persisted record [seq].
  void _drive(int seq, Future<Object?> done, TransferKind kind, String path) {
    done.then((_) async {
      _running.remove(seq);
      _removeActive(kind, path);
      await _queue.remove(seq);
      _emit(TransferEventType.completed, kind, path);
    }).catchError((Object e) async {
      _running.remove(seq);
      _removeActive(kind, path);
      final rec = await _queue.get(seq);
      if (rec == null) return;
      final attempt = rec.attempt + 1;
      await _queue.update(rec.copyWith(
          status: TransferStatus.failed, attempt: attempt, lastError: '$e'));
      _emit(TransferEventType.failed, kind, path, e);
      if (attempt <= _retry.maxAttempts) _scheduleRetry(seq, attempt);
    });
  }

  Duration _backoff(int attempt) {
    final ms = _retry.baseDelay.inMilliseconds * (1 << (attempt - 1));
    final capped = ms.clamp(0, _retry.maxDelay.inMilliseconds);
    return Duration(milliseconds: capped);
  }

  void _scheduleRetry(int seq, int attempt) {
    Timer(_backoff(attempt), () => unawaited(_restart(seq)));
  }

  /// Recreates the task for a persisted record and re-drives it.
  Future<void> _restart(int seq) async {
    if (_disposed || _running.contains(seq)) return;
    final rec = await _queue.get(seq);
    if (rec == null) return;
    _running.add(seq);
    await _queue.update(rec.copyWith(status: TransferStatus.running));
    _emit(TransferEventType.retrying, rec.kind, rec.path);

    final ref = _ref(rec.path);
    if (rec.kind == TransferKind.download) {
      // Destination must still be known; if it's gone, drop the record.
      if (rec.localPath == null) {
        _running.remove(seq);
        await _queue.remove(seq);
        return;
      }
      final task = DownloadTask.start(
        reference: ref,
        saveTo: rec.localPath!,
        maxRetries: 0,
        httpClient: _httpClient,
      );
      _activeDownloads[rec.path] = task;
      _drive(seq, task.whenDone, TransferKind.download, rec.path);
    } else {
      // Upload: the source file must still exist; if it's gone, drop the record.
      if (rec.localPath == null) {
        _running.remove(seq);
        await _queue.remove(seq);
        return;
      }
      final task = UploadTask.start(
        reference: ref,
        localPath: rec.localPath!,
        mimeType: rec.mimeType ?? 'application/octet-stream',
        metadata: rec.metadata,
        multipartThreshold: rec.multipartThreshold ?? _multipartThreshold,
        maxRetries: 0,
        httpClient: _httpClient,
      );
      _activeUploads[rec.path] = task;
      _drive(seq, task.whenDone, TransferKind.upload, rec.path);
    }
  }

  /// Recreates tasks for every persisted record (after an app restart).
  Future<void> rehydrate() async {
    for (final rec in await _queue.all()) {
      await _restart(rec.seq);
    }
  }

  Future<void> resumeDownloads() => _resumeKind(TransferKind.download);
  Future<void> resumeUploads() => _resumeKind(TransferKind.upload);

  Future<void> _resumeKind(TransferKind kind) async {
    for (final rec in await _queue.all()) {
      if (rec.kind != kind) continue;
      if (_running.contains(rec.seq)) continue;
      await _queue.update(rec.copyWith(attempt: 0)); // reset cap on manual resume
      await _restart(rec.seq);
    }
  }

  Future<void> resumePath(String path) async {
    for (final rec in await _queue.all()) {
      if (rec.path == path && !_running.contains(rec.seq)) {
        await _restart(rec.seq);
      }
    }
  }

  /// Backstop: retry failed records still within the attempt cap.
  Future<void> retryFailed() async {
    for (final rec in await _queue.all()) {
      if (rec.status == TransferStatus.failed &&
          rec.attempt <= _retry.maxAttempts &&
          !_running.contains(rec.seq)) {
        await _restart(rec.seq);
      }
    }
  }

  void _emit(TransferEventType type, TransferKind kind, String path,
      [Object? error]) {
    if (!_events.isClosed) {
      _events.add(
          TransferEvent(type: type, kind: kind, path: path, error: error));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _poll?.cancel();
    if (!_events.isClosed) await _events.close();
  }
}
