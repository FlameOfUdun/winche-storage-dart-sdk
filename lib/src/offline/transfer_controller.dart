import 'dart:async';

import 'package:dio/dio.dart';

import '../api/winche_storage_api.dart';
import '../child_reference.dart';
import '../tasks/managed_transfer.dart';
import '../tasks/upload_task.dart';
import 'storage_local_store.dart';
import 'transfer_event.dart';
import 'transfer_failure.dart';
import 'transfer_queue.dart';
import 'transfer_record.dart';
import 'upload_pin_sink.dart';

export 'transfer_event.dart' show TransferRetryConfig;

/// The durable upload outbox: persists in-flight uploads and resumes them after
/// restarts and failures, driving the [UploadTask] engine. The controller is
/// the sole retry authority — tasks are created with `maxRetries: 0` (attempt
/// once) and the controller schedules durable backoff retries itself.
///
/// Uploads only, deliberately. An upload is the only copy of something: lose
/// the queue and the work is gone. A download is a cache fill whose bytes stay
/// authoritative on the server, so losing it costs bandwidth and never data.
/// Downloads are therefore one-shot with in-session retry, tracked for
/// observability by `LiveTaskRegistry` rather than persisted here.
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

  /// Consecutive pauses per seq, driving only the backoff delay between probes.
  /// Deliberately in-memory and separate from `TransferRecord.attempt`: a paused
  /// transfer probes on the same curve as a retrying one but spends no attempts,
  /// so it can wait out an expired token indefinitely without being dropped.
  final Map<int, int> _pauseProbes = {};

  /// Live tasks keyed by path — de-dups concurrent starts for the same path.
  final Map<String, ManagedUploadTask> _activeUploads = {};

  Timer? _poll;

  /// Pending backoff timers, tracked so [close] can cancel them. Left untracked
  /// they outlive the controller and fire into a store that has been closed.
  final Set<Timer> _retryTimers = {};

  bool _closed = false;

  /// Whether [close] has been called. Every drive-loop continuation is gated on
  /// it, so anything the teardown itself triggers becomes a no-op.
  bool get isClosed => _closed;

  /// Set by the facade after construction (the catalog is built later). Enables
  /// finalizing pinned uploads on completion. Null when the file cache is off.
  UploadPinSink? pinSink;

  Stream<TransferEvent> get events => _events.stream;

  void _assertOpen() {
    if (_closed) {
      throw StateError('WincheStorage has been closed.');
    }
  }

  ChildReference _ref(String path) => ChildReference(
        path: path,
        api: _api,
        multipartThreshold: _multipartThreshold,
        directoryResolver: _directoryResolver,
      );

  UploadTask startUpload(
    ChildReference ref, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    bool pinned = false,
  }) {
    _assertOpen();
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
      // tracked upload guarantees its cached copy is committed.
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

  Future<void> _registerUpload(
    String path, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    required bool pinned,
  }) async {
    final seq = await _existingSeq(path, localPath: localPath) ??
        await _queue.enqueue((seq) => TransferRecord(
              seq: seq,
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
    _wireHandle(seq, path);
    _emit(TransferEventType.started, path);
    unawaited(_drive(seq, path));
  }

  /// Reuses the seq of an existing record for [path], resetting it to running.
  /// Returns null when no such record exists (caller enqueues fresh).
  Future<int?> _existingSeq(String path, {String? localPath}) async {
    for (final rec in await _queue.all()) {
      if (rec.path == path) {
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
    // The exponent is clamped, not just the result: a paused transfer probes
    // indefinitely, and past ~30 doublings the shift itself overflows (on the
    // web, silently) long before the clamp below could rein it in.
    final shift = (attempt - 1).clamp(0, 30);
    final ms = _retry.baseDelay.inMilliseconds * (1 << shift);
    final capped = ms.clamp(0, _retry.maxDelay.inMilliseconds);
    return Duration(milliseconds: capped);
  }

  /// Wires the live handle's controller callbacks. Called once [seq] is known
  /// and always before the handle is first driven:
  ///
  /// * `onResume` — a paused tracked upload re-enters the drive loop instead of
  ///   self-driving.
  /// * `onBeforeComplete` — the durable record is dropped and `completed`
  ///   emitted *before* `whenDone` resolves, so a caller that awaits an upload
  ///   never sees it still sitting in `pendingUploads()`.
  void _wireHandle(int seq, String path) {
    void onResume() {
      if (_closed || _running.contains(seq)) return;
      _running.add(seq);
      unawaited(_drive(seq, path));
    }

    Future<void> onBeforeComplete() async {
      if (_closed) return;
      _running.remove(seq);
      _pauseProbes.remove(seq);
      _activeUploads.remove(path);
      await _queue.remove(seq);
      _emit(TransferEventType.completed, path);
    }

    final handle = _activeUploads[path];
    handle?.onResume = onResume;
    handle?.onBeforeComplete = onBeforeComplete;
  }

  /// Runs one attempt of the stable handle for [seq]/[path] and settles the
  /// outcome: finalize on success, or route the failure through
  /// [classifyTransferFailure].
  Future<void> _drive(int seq, String path) async {
    final task = _activeUploads[path];
    if (task == null) {
      _running.remove(seq);
      return;
    }
    try {
      await task.runOnce();
    } catch (e) {
      _running.remove(seq);
      // Closing aborts in-flight attempts; the record is reset by close() and
      // the store is about to go away, so touching either here is both useless
      // and unsafe.
      if (_closed) return;
      // Pause/cancel make runOnce return normally rather than throw, so a
      // non-running handle here means the abort raced the failure.
      final state = task.transferState;
      if (state == ManagedTransferState.cancelled ||
          state == ManagedTransferState.paused) {
        return;
      }
      await _settleFailure(seq, path, task, e);
      return;
    }
    // runOnce returned without throwing: complete, cancelled, paused, or
    // aborted back to queued by close().
    _running.remove(seq);
    if (_closed) return;
    _pauseProbes.remove(seq);
    switch (task.transferState) {
      case ManagedTransferState.complete:
        // Nothing to do: the handle ran `onBeforeComplete` — dropping the
        // record and emitting `completed` — before it completed, and a `pinned`
        // upload finalized its cache copy via onPinFinalize before that. Both
        // are settled by the time a caller's `whenDone` resolves.
        break;
      case ManagedTransferState.cancelled:
        _activeUploads.remove(path);
        await _queue.remove(seq);
      default:
        // paused / queued — stop driving; resume() re-enters via onResume.
        break;
    }
  }

  /// Applies the failure taxonomy to a thrown attempt. See
  /// [classifyTransferFailure] for why one uniform "count an attempt then give
  /// up" policy is not safe.
  Future<void> _settleFailure(
    int seq,
    String path,
    ManagedTransfer task,
    Object e,
  ) async {
    final rec = await _queue.get(seq);
    if (rec == null) {
      _activeUploads.remove(path);
      return;
    }

    switch (classifyTransferFailure(e)) {
      case TransferFailureClass.pause:
        // No attempt counted, record and handle both survive: waiting out an
        // expired token or a dead network must never consume the retry budget.
        await _queue.update(
            rec.copyWith(status: TransferStatus.paused, lastError: '$e'));
        _emit(TransferEventType.paused, path, e);
        // Keep probing on the usual backoff so a brief blip recovers in about a
        // second rather than waiting out the backstop poll. The counter driving
        // the delay is in-memory and separate from `rec.attempt`, which is what
        // must not advance — this schedules retries, it does not spend them.
        final probe = (_pauseProbes[seq] ?? 0) + 1;
        _pauseProbes[seq] = probe;
        _scheduleRetry(seq, probe, path);

      case TransferFailureClass.terminal:
        _pauseProbes.remove(seq);
        _activeUploads.remove(path);
        await _queue.remove(seq);
        _emit(TransferEventType.failed, path, e, rec);
        task.failPermanently(e);
        task.whenDone.ignore(); // consume the error so it is not unhandled

      case TransferFailureClass.retry:
        _pauseProbes.remove(seq);
        final attempt = rec.attempt + 1;
        final updated = rec.copyWith(
            status: TransferStatus.failed, attempt: attempt, lastError: '$e');
        await _queue.update(updated);
        _emit(TransferEventType.failed, path, e, updated);
        if (attempt > _retry.maxAttempts) {
          // The record stays queued as `failed` so `pendingUploads()` can still
          // surface it; only the handle is settled.
          _activeUploads.remove(path);
          task.failPermanently(e);
          task.whenDone.ignore();
          return;
        }
        _emit(TransferEventType.retrying, path);
        _scheduleRetry(seq, attempt, path);
    }
  }

  void _scheduleRetry(int seq, int attempt, String path) {
    late final Timer timer;
    timer = Timer(_backoff(attempt), () {
      _retryTimers.remove(timer);
      if (_closed) return;
      unawaited(_drive(seq, path));
    });
    _retryTimers.add(timer);
  }

  /// Recreates a managed handle for a persisted record (if not already live) and
  /// drives it. Used by rehydrate / resume / the retry backstop.
  Future<void> _restart(int seq) async {
    if (_closed || _running.contains(seq)) return;
    final rec = await _queue.get(seq);
    if (rec == null) return;
    final ref = _ref(rec.path);
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
              ? (confirmed) => pinSink!.finalizeUploadPin(rec.path, confirmed)
              : null,
        );
    _activeUploads[rec.path] = task;
    _running.add(seq);
    _wireHandle(seq, rec.path);
    await _queue.update(rec.copyWith(status: TransferStatus.running));
    _emit(TransferEventType.retrying, rec.path);
    unawaited(_drive(seq, rec.path));
  }

  /// Recreates tasks for every persisted record (after an app restart).
  Future<void> rehydrate() async {
    // Drop any download rows left by a version that still queued them, before
    // anything can try to drive one.
    await _queue.purgeLegacyDownloads();
    for (final rec in await _queue.all()) {
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

  /// Removes any queued or in-flight upload for [path] — e.g. after the file is
  /// deleted — so it is not resumed or retried and leaves no orphaned record.
  /// Cancels a live task (best-effort) and drops the persisted record(s).
  Future<void> removePath(String path) async {
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
      _pauseProbes.remove(rec.seq);
      await _queue.remove(rec.seq);
    }
  }

  /// A snapshot of the persisted upload queue (pending, running, or failed
  /// records). Completed uploads are removed from the queue, so they never
  /// appear here.
  Future<List<TransferRecord>> pendingUploads() => _queue.all();

  /// The live tracked upload handle for [path], or null when none is in flight.
  /// Lets a UI reattach to an upload after a restart.
  UploadTask? uploadFor(String path) => _activeUploads[path];

  /// Backstop: re-drive failed records still within the attempt cap, and every
  /// paused one. Paused records are re-driven unconditionally — the condition
  /// that halted them (an expired token, no network) clears without warning, and
  /// they carry no attempt budget to exhaust.
  Future<void> retryFailed() async {
    for (final rec in await _queue.all()) {
      if (_running.contains(rec.seq)) continue;
      final eligible = rec.status == TransferStatus.paused ||
          (rec.status == TransferStatus.failed &&
              rec.attempt <= _retry.maxAttempts);
      if (eligible) await _restart(rec.seq);
    }
  }

  /// Re-drives every upload halted by a pause — the thing to call after
  /// refreshing an auth token, rather than waiting out the backstop poll.
  Future<void> resumeUploads() async {
    for (final rec in await _queue.all()) {
      if (_running.contains(rec.seq)) continue;
      await _queue.update(rec.copyWith(attempt: 0)); // reset cap on manual resume
      await _restart(rec.seq);
    }
  }

  void _emit(TransferEventType type, String path,
      [Object? error, TransferRecord? record]) {
    if (!_events.isClosed) {
      _events.add(TransferEvent(
          type: type,
          kind: TransferKind.upload,
          path: path,
          error: error,
          record: record));
    }
  }

  /// Stands the controller down without waiting on the network.
  ///
  /// In-flight attempts are aborted rather than drained, so a user switch cannot
  /// block behind a large upload, and `running` records are reset to `pending`
  /// so the next session picks them up. Idempotent. The caller closes the store
  /// afterwards — everything here must finish first.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _poll?.cancel();
    _poll = null;
    for (final t in _retryTimers) {
      t.cancel();
    }
    _retryTimers.clear();

    // Abort in-flight HTTP. Not `cancel()`: for an upload that deletes the
    // remote file, and closing the SDK says nothing about whether the upload
    // should exist.
    for (final t in _activeUploads.values) {
      t.abortForClose();
    }
    _activeUploads.clear();
    _running.clear();
    _pauseProbes.clear();

    // Leave nothing marked `running`: on the next launch that would look like a
    // transfer already being driven by someone.
    for (final rec in await _queue.all()) {
      if (rec.status == TransferStatus.running) {
        await _queue.update(rec.copyWith(status: TransferStatus.pending));
      }
    }

    if (!_events.isClosed) await _events.close();
  }
}
