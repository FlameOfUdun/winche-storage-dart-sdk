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
import 'upload_pin_sink.dart';

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
  final Map<String, ManagedDownloadTask> _activeDownloads = {};
  final Map<String, ManagedUploadTask> _activeUploads = {};

  Timer? _poll;
  bool _disposed = false;

  /// Set by the facade after construction (the catalog is built later). Enables
  /// finalizing pinned uploads on completion. Null when offline cache is off.
  UploadPinSink? pinSink;

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
    final task = ManagedDownloadTask(
      reference: ref,
      saveTo: saveTo,
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
    bool pinned = false,
  }) {
    final existing = _activeUploads[ref.path];
    if (existing != null) return existing;
    final sink = pinned ? pinSink : null;
    final task = ManagedUploadTask(
      reference: ref,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      httpClient: _httpClient,
      stageSource:
          sink == null ? null : () => sink.stageUpload(ref.path, localPath),
      // Finalize the pin within the task (before whenDone), so a completed
      // tracked upload guarantees its offline copy is committed.
      onPinFinalize: sink == null
          ? null
          : (confirmed) => sink.finalizeUploadPin(ref.path, confirmed),
    );
    _activeUploads[ref.path] = task;
    unawaited(_registerUpload(
      ref.path,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      pinned: pinned,
    ));
    return task;
  }

  Future<void> _registerDownload(String path, DownloadTask task) async {
    final seq = await _existingSeq(TransferKind.download, path,
            localPath: task.saveTo) ??
        await _queue.enqueue((seq) => TransferRecord(
              seq: seq,
              kind: TransferKind.download,
              path: path,
              localPath: task.saveTo,
              mimeType: null,
              metadata: null,
              multipartThreshold: null,
              status: TransferStatus.running,
              attempt: 0,
              lastError: null,
              createdAt: DateTime.now(),
            ));
    _running.add(seq);
    _wireResume(seq, TransferKind.download, path);
    _emit(TransferEventType.started, TransferKind.download, path);
    unawaited(_driveDownload(seq, path));
  }

  Future<void> _registerUpload(
    String path, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    required bool pinned,
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
                  pinned: pinned,
                ));
    _running.add(seq);
    _wireResume(seq, TransferKind.upload, path);
    _emit(TransferEventType.started, TransferKind.upload, path);
    unawaited(_driveUpload(seq, path));
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

  Duration _backoff(int attempt) {
    final ms = _retry.baseDelay.inMilliseconds * (1 << (attempt - 1));
    final capped = ms.clamp(0, _retry.maxDelay.inMilliseconds);
    return Duration(milliseconds: capped);
  }

  /// Wires the live handle's `onResume` so a paused tracked transfer re-enters
  /// the controller's drive loop (instead of self-driving) when resumed.
  void _wireResume(int seq, TransferKind kind, String path) {
    void cb() {
      if (_disposed || _running.contains(seq)) return;
      _running.add(seq);
      if (kind == TransferKind.upload) {
        unawaited(_driveUpload(seq, path));
      } else {
        unawaited(_driveDownload(seq, path));
      }
    }

    if (kind == TransferKind.upload) {
      _activeUploads[path]?.onResume = cb;
    } else {
      _activeDownloads[path]?.onResume = cb;
    }
  }

  /// Runs one attempt of the stable upload handle for [seq]/[path], scheduling a
  /// retry of the same handle on transient failure and finalizing on success.
  Future<void> _driveUpload(int seq, String path) async {
    final task = _activeUploads[path];
    if (task == null) {
      _running.remove(seq);
      return;
    }
    try {
      await task.runOnce();
    } catch (e) {
      // Transient failure — the handle is back to `queued`. (Pause/cancel make
      // runOnce return normally, not throw, so they're handled below.)
      if (task.state.status == UploadTaskStatus.cancelled ||
          task.state.status == UploadTaskStatus.paused) {
        _running.remove(seq);
        return;
      }
      final rec = await _queue.get(seq);
      if (rec == null) {
        _running.remove(seq);
        _activeUploads.remove(path);
        return;
      }
      final attempt = rec.attempt + 1;
      await _queue.update(rec.copyWith(
          status: TransferStatus.failed, attempt: attempt, lastError: '$e'));
      _emit(TransferEventType.failed, TransferKind.upload, path, e);
      if (attempt > _retry.maxAttempts) {
        _running.remove(seq);
        _activeUploads.remove(path);
        task.failPermanently(e);
        task.whenDone.ignore(); // consume the error so it is not unhandled
        return;
      }
      _emit(TransferEventType.retrying, TransferKind.upload, path);
      _scheduleRetry(seq, attempt, TransferKind.upload, path);
      return;
    }
    // runOnce returned without throwing: complete, paused, or cancelled.
    switch (task.state.status) {
      case UploadTaskStatus.complete:
        // The task finalized any `pinned` cache copy itself (via onPinFinalize)
        // before completing, so the pin is already committed here.
        _running.remove(seq);
        _activeUploads.remove(path);
        await _queue.remove(seq);
        _emit(TransferEventType.completed, TransferKind.upload, path);
      case UploadTaskStatus.cancelled:
        _running.remove(seq);
        _activeUploads.remove(path);
        await _queue.remove(seq);
      default:
        // paused — stop driving; resume() re-enters via onResume.
        _running.remove(seq);
    }
  }

  /// Download counterpart of [_driveUpload] (no pin step).
  Future<void> _driveDownload(int seq, String path) async {
    final task = _activeDownloads[path];
    if (task == null) {
      _running.remove(seq);
      return;
    }
    try {
      await task.runOnce();
    } catch (e) {
      if (task.state.status == DownloadTaskStatus.cancelled ||
          task.state.status == DownloadTaskStatus.paused) {
        _running.remove(seq);
        return;
      }
      final rec = await _queue.get(seq);
      if (rec == null) {
        _running.remove(seq);
        _activeDownloads.remove(path);
        return;
      }
      final attempt = rec.attempt + 1;
      await _queue.update(rec.copyWith(
          status: TransferStatus.failed, attempt: attempt, lastError: '$e'));
      _emit(TransferEventType.failed, TransferKind.download, path, e);
      if (attempt > _retry.maxAttempts) {
        _running.remove(seq);
        _activeDownloads.remove(path);
        task.failPermanently(e);
        task.whenDone.ignore(); // consume the error so it is not unhandled
        return;
      }
      _emit(TransferEventType.retrying, TransferKind.download, path);
      _scheduleRetry(seq, attempt, TransferKind.download, path);
      return;
    }
    // runOnce returned without throwing: complete, paused, or cancelled.
    switch (task.state.status) {
      case DownloadTaskStatus.complete:
        _running.remove(seq);
        _activeDownloads.remove(path);
        await _queue.remove(seq);
        _emit(TransferEventType.completed, TransferKind.download, path);
      case DownloadTaskStatus.cancelled:
        _running.remove(seq);
        _activeDownloads.remove(path);
        await _queue.remove(seq);
      default:
        // paused — stop driving; resume() re-enters via onResume.
        _running.remove(seq);
    }
  }

  void _scheduleRetry(int seq, int attempt, TransferKind kind, String path) {
    Timer(_backoff(attempt), () {
      if (_disposed) return;
      if (kind == TransferKind.upload) {
        unawaited(_driveUpload(seq, path));
      } else {
        unawaited(_driveDownload(seq, path));
      }
    });
  }

  /// Recreates a managed handle for a persisted record (if not already live) and
  /// drives it. Used by rehydrate / resume / the retry backstop.
  Future<void> _restart(int seq) async {
    if (_disposed || _running.contains(seq)) return;
    final rec = await _queue.get(seq);
    if (rec == null) return;
    final ref = _ref(rec.path);
    if (rec.kind == TransferKind.download) {
      if (rec.localPath == null) {
        await _queue.remove(seq);
        return;
      }
      final task = _activeDownloads[rec.path] ??
          ManagedDownloadTask(
            reference: ref,
            saveTo: rec.localPath!,
            httpClient: _httpClient,
          );
      _activeDownloads[rec.path] = task;
      _running.add(seq);
      _wireResume(seq, TransferKind.download, rec.path);
      await _queue.update(rec.copyWith(status: TransferStatus.running));
      _emit(TransferEventType.retrying, TransferKind.download, rec.path);
      unawaited(_driveDownload(seq, rec.path));
    } else {
      var source = rec.localPath;
      if (rec.pinned && pinSink != null) {
        final staged = await pinSink!.resolveStagedUpload(rec.path);
        if (staged != null) source = staged;
      }
      if (source == null) {
        await _queue.remove(seq);
        return;
      }
      final task = _activeUploads[rec.path] ??
          ManagedUploadTask(
            reference: ref,
            localPath: source,
            mimeType: rec.mimeType ?? 'application/octet-stream',
            metadata: rec.metadata,
            multipartThreshold: rec.multipartThreshold ?? _multipartThreshold,
            httpClient: _httpClient,
            // Resumed pinned upload: finalize from the staged copy (or record a
            // deferred entry) within the task, before whenDone.
            onPinFinalize: (rec.pinned && pinSink != null)
                ? (confirmed) =>
                    pinSink!.finalizeUploadPin(rec.path, confirmed)
                : null,
          );
      _activeUploads[rec.path] = task;
      _running.add(seq);
      _wireResume(seq, TransferKind.upload, rec.path);
      await _queue.update(rec.copyWith(status: TransferStatus.running));
      _emit(TransferEventType.retrying, TransferKind.upload, rec.path);
      unawaited(_driveUpload(seq, rec.path));
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

  /// Removes any queued or in-flight transfer for [path] — e.g. after the file
  /// is deleted — so it is not resumed or retried and leaves no orphaned record.
  /// Cancels a live task (best-effort) and drops the persisted record(s).
  Future<void> removePath(String path) async {
    // Stop any live task so it stops touching the deleted path.
    _activeDownloads.remove(path)?.cancel();
    final upload = _activeUploads.remove(path);
    if (upload != null) {
      try {
        await upload.cancel();
      } catch (_) {
        // already terminal — nothing to cancel
      }
    }
    // Drop persisted records so the backstop / a restart won't resume them.
    for (final rec in await _queue.all()) {
      if (rec.path != path) continue;
      _running.remove(rec.seq);
      await _queue.remove(rec.seq);
    }
  }

  /// A snapshot of the persisted transfer queue (pending, running, or failed
  /// records), optionally filtered by [kind]. Completed transfers are removed
  /// from the queue, so they never appear here.
  Future<List<TransferRecord>> pendingTransfers({TransferKind? kind}) async {
    final all = await _queue.all();
    if (kind == null) return all;
    return [for (final r in all) if (r.kind == kind) r];
  }

  /// The live tracked upload/download handle for [path], or null when none is in
  /// flight. Lets a UI reattach to a transfer after a restart.
  UploadTask? uploadFor(String path) => _activeUploads[path];
  DownloadTask? downloadFor(String path) => _activeDownloads[path];

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
