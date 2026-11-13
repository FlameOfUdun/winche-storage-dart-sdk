import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:winche_core/winche_core.dart';

import '../api/winche_storage_exception.dart';
import '../child_reference.dart';
import '../file_snapshot.dart';
import '../models/file_data.dart';
import '../models/upload_status.dart';
import 'managed_transfer.dart';
import 'transfer_http.dart';

enum UploadTaskStatus {
  queued,
  running,
  paused,
  complete,
  failed,
  cancelled,
}

final class UploadTaskState {
  final UploadTaskStatus status;
  final double progress;

  const UploadTaskState({
    required this.status,
    required this.progress,
  });

  UploadTaskState withStatus(UploadTaskStatus newStatus) =>
      UploadTaskState(status: newStatus, progress: progress);
  UploadTaskState withProgress(double newProgress) =>
      UploadTaskState(status: status, progress: newProgress);
}

abstract class UploadTask {
  final ChildReference reference;
  final String? localPath;
  final Uint8List? bytes;
  final String mimeType;
  final Map<String, dynamic>? metadata;
  final int multipartThreshold;
  final int maxRetries;
  final Duration retryBaseDelay;
  final WincheHttp _httpClient;
  final Future<String> Function()? _stageSource;
  final Future<String?> Function(FileData confirmed)? _onPinFinalize;
  final Future<void> Function(FileData confirmed)? _onPinDeferred;

  /// Set once a stage succeeds; guards against re-staging on pause/resume.
  String? _stagedPath;

  /// Where the cached copy landed, set by [_settlePin] when the pin committed.
  /// Null for an unpinned upload and for one whose copy was deferred — in both
  /// cases this device holds no bytes for the file.
  String? _pinnedPath;

  final _stateController = StreamController<UploadTaskState>.broadcast();
  final _taskCompleter = Completer<FileSnapshot?>();

  TransferAbort? _cancelToken;
  UploadTaskState _state;

  UploadTaskState get state => _state;
  Stream<UploadTaskState> get stateStream => _stateController.stream;
  /// The confirmed server record once the upload lands, or null if it was
  /// cancelled. Errors on permanent failure.
  ///
  /// For a `cache: true` upload the snapshot also carries the copy this upload
  /// committed on this device (`isCached` / `localPath`) — a caller never has
  /// to read it back. Both stay unset when the copy was deferred, since no
  /// bytes landed here.
  Future<FileSnapshot?> get whenDone => _taskCompleter.future;

  UploadTask._({
    required this.reference,
    this.localPath,
    this.bytes,
    required this.mimeType,
    this.metadata,
    required this.multipartThreshold,
    required this.maxRetries,
    required this.retryBaseDelay,
    required WincheHttp httpClient,
    required UploadTaskStatus initialStatus,
    Future<String> Function()? stageSource,
    Future<String?> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  })  : _httpClient = httpClient,
        _stageSource = stageSource,
        _onPinFinalize = onPinFinalize,
        _onPinDeferred = onPinDeferred,
        _state = UploadTaskState(status: initialStatus, progress: 0.0);

  /// Creates and immediately starts an [UploadTask] from a local file path.
  ///
  /// [httpClient] sends the bytes to the signed link; a shared client when omitted.
  factory UploadTask.start({
    required ChildReference reference,
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(seconds: 1),
    WincheHttp? httpClient,
    Future<String> Function()? stageSource,
    Future<String?> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  }) {
    final client = httpClient ?? defaultTransferHttp;

    final task = _DirectUploadTask._(
      reference: reference,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      httpClient: client,
      stageSource: stageSource,
      onPinFinalize: onPinFinalize,
      onPinDeferred: onPinDeferred,
    );

    unawaited(task._runUnmanaged());
    return task;
  }

  /// Creates and immediately starts an [UploadTask] from raw bytes.
  ///
  /// [httpClient] sends the bytes to the signed link; a shared client when omitted.
  factory UploadTask.startFromBytes({
    required ChildReference reference,
    required Uint8List bytes,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(seconds: 1),
    WincheHttp? httpClient,
    Future<String> Function()? stageSource,
    Future<String?> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  }) {
    final client = httpClient ?? defaultTransferHttp;

    final task = _DirectUploadTask._(
      reference: reference,
      bytes: bytes,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      httpClient: client,
      stageSource: stageSource,
      onPinFinalize: onPinFinalize,
      onPinDeferred: onPinDeferred,
    );

    unawaited(task._runUnmanaged());
    return task;
  }

  Future<FileData> _attemptOnce() async {
    // Pin-on-upload: stage a safe local copy and upload *from* it, so the
    // upload no longer depends on the caller's original file. Best-effort —
    // on staging failure we upload from the original source and mark the copy
    // deferred after confirm.
    String? effPath = localPath;
    Uint8List? effBytes = bytes;
    if (_stageSource != null) {
      if (_stagedPath == null) {
        try {
          _stagedPath = await _stageSource();
        } catch (_) {
          _stagedPath = null; // fall back to the original source
        }
      }
      if (_stagedPath != null) {
        effPath = _stagedPath;
        effBytes = null;
      }
    }

    final File? localFile;
    final int sizeBytes;

    if (effBytes != null) {
      localFile = null;
      sizeBytes = effBytes.length;
    } else {
      localFile = File(effPath!);
      if (!await localFile.exists()) {
        throw Exception('Local file not found at $effPath');
      }
      sizeBytes = (await localFile.stat()).size;
    }

    // Files at or below the threshold go through the backend's single-shot
    // upload (`:upload`); larger files are split into multipart parts.
    final isMultipart = sizeBytes > multipartThreshold;

    var byteOffset = 0;
    var partNumber = 1;

    var existingRecord = await reference.api.getFile(reference.path);

    if (existingRecord == null) {
      existingRecord = await reference.api
          .setFile(reference.path, mimeType, sizeBytes, metadata: metadata);
    } else {
      // A record matches the upload when both its declared size and MIME type
      // are identical — only then can it be safely skipped or resumed.
      final matches = existingRecord.sizeBytes == sizeBytes &&
          existingRecord.mimeType == mimeType;

      if (existingRecord.uploadStatus == UploadStatus.complete) {
        if (matches) {
          // Already uploaded identical content — nothing to do.
          await _settlePin(existingRecord);
          return existingRecord;
        }
        // Overwrite the completed file with the new content.
        existingRecord = await _replaceRecord(sizeBytes);
      } else if (matches) {
        // Resume the in-progress upload of the same content. Single-shot
        // uploads can't be resumed mid-transfer, so only multipart consults
        // the already-completed parts.
        if (isMultipart) {
          final parts = await reference.api.listParts(reference.path);
          if (parts.isNotEmpty) {
            byteOffset =
                parts.map((p) => p.size ?? 0).reduce((a, b) => a + b);
            partNumber = parts.length + 1;
          }
        }
      } else {
        // An abandoned attempt for different content — discard it and start
        // fresh so a prior failure doesn't poison this path.
        existingRecord = await _replaceRecord(sizeBytes);
      }
    }

    if (isMultipart) {
      if (byteOffset > 0) _setProgress(byteOffset / sizeBytes);

      while (byteOffset < sizeBytes) {
        final chunkSize =
            (sizeBytes - byteOffset).clamp(0, multipartThreshold);
        await _uploadPartWithRetry(
          localFile: localFile,
          bytes: effBytes,
          partNumber: partNumber,
          byteOffset: byteOffset,
          chunkSize: chunkSize,
          sizeBytes: sizeBytes,
        );
        byteOffset += chunkSize;
        partNumber++;
      }
    } else {
      await _uploadWholeWithRetry(
        localFile: localFile,
        bytes: effBytes,
        sizeBytes: sizeBytes,
      );
    }

    final confirmed = await reference.api.confirmUpload(reference.path);
    await _settlePin(confirmed);
    return confirmed;
  }

  /// Deletes any existing record/parts at the path and creates a fresh one for
  /// the given [sizeBytes]. Used to overwrite a completed file or to discard an
  /// abandoned attempt whose content no longer matches.
  Future<FileData> _replaceRecord(int sizeBytes) async {
    await reference.api.deleteFile(reference.path);
    return reference.api
        .setFile(reference.path, mimeType, sizeBytes, metadata: metadata);
  }

  /// Uploads the whole file/bytes in a single signed PUT (the `:upload` path),
  /// retrying with exponential backoff. Used for files at or below the
  /// multipart threshold, including empty files.
  Future<void> _uploadWholeWithRetry({
    required File? localFile,
    required Uint8List? bytes,
    required int sizeBytes,
  }) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final session =
            await reference.api.generateFileUploadUrl(reference.path);
        await _put(
          session.url,
          () => bytes != null ? Stream.value(bytes) : localFile!.openRead(),
          sizeBytes,
          onSent: (sent) {
            if (sizeBytes > 0) _setProgress(sent / sizeBytes);
          },
          failure: (code) => 'Failed to upload file: HTTP $code',
        );
        return;
      } on WincheHttpException catch (e) {
        if (!isTransferNetworkFailure(e)) rethrow;

        final isLastAttempt = attempt == maxRetries;
        if (isLastAttempt) rethrow;

        final delay = retryBaseDelay * (1 << attempt);
        await Future<void>.delayed(delay);
        if (!_isRunning) return;
      }
    }
  }

  Future<void> _uploadPartWithRetry({
    required File? localFile,
    required Uint8List? bytes,
    required int partNumber,
    required int byteOffset,
    required int chunkSize,
    required int sizeBytes,
  }) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final session = await reference.api
            .generatePartUploadUrl(reference.path, partNumber);
        await _put(
          session.url,
          () => bytes != null
              ? Stream.value(bytes.sublist(byteOffset, byteOffset + chunkSize))
              : localFile!.openRead(byteOffset, byteOffset + chunkSize),
          chunkSize,
          onSent: (sent) => _setProgress((byteOffset + sent) / sizeBytes),
          failure: (code) => 'Failed to upload part $partNumber: HTTP $code',
        );
        return;
      } on WincheHttpException catch (e) {
        if (!isTransferNetworkFailure(e)) rethrow;

        final isLastAttempt = attempt == maxRetries;
        if (isLastAttempt) rethrow;

        final delay = retryBaseDelay * (1 << attempt);
        await Future<void>.delayed(delay);
        if (!_isRunning) return;
      }
    }
  }

  /// One PUT of [length] bytes to a signed link. An answer other than 200/201
  /// throws a plain [Exception] worded by [failure]: the bucket refused, and
  /// only a fresh session (a new attempt) can help. No answer at all throws the
  /// [WincheHttpException], which the callers retry.
  Future<void> _put(String url, Stream<List<int>> Function() body, int length,
      {required void Function(int sent) onSent, required String Function(int code) failure}) async {
    try {
      final response = await _httpClient.send(WincheRequest.streamed(
        'PUT',
        Uri.parse(url),
        body: body,
        length: length,
        headers: {'content-type': mimeType},
        auth: WincheRequestAuth.none,
        // Tries are this task's to count, with its own backoff.
        idempotent: false,
        timeout: transferTimeout,
        abortTrigger: _cancelToken?.trigger,
        onSendProgress: (sent, _) => onSent(sent),
        service: 'storage',
      ));
      if (response.status != 200 && response.status != 201) throw Exception(failure(response.status));
    } on WincheHttpException catch (e) {
      final status = e.status;
      if (status != null) throw Exception(failure(status));
      rethrow;
    }
  }

  bool get _isRunning => _state.status == UploadTaskStatus.running;

  /// Pauses the upload mid-flight. Call [resume] to continue from the last
  /// completed part.
  void pause() {
    if (_state.status != UploadTaskStatus.running) {
      throw StateError(
          'Cannot pause: task is ${_state.status} (expected running)');
    }
    _setStatus(UploadTaskStatus.paused);
    _cancelToken?.abort();
    _cancelToken = null;
  }

  /// Resumes a paused upload.
  void resume();

  /// Aborts an in-flight attempt because `WincheStorage.close()` was called.
  ///
  /// Deliberately not [cancel], which deletes the remote file: closing the SDK
  /// says nothing about whether the upload should exist. A managed upload
  /// returns to `queued` and resumes from its durable record next session; a
  /// one-shot upload has no record to resume from, so it settles with
  /// [StorageCancelledException].
  void abortForClose();

  /// Cancels in-flight HTTP without touching status or completion. Shared by
  /// the two [abortForClose] implementations.
  void _abortInFlight() {
    _cancelToken?.abort();
    _cancelToken = null;
  }

  /// Cancels the upload, deletes the remote file, and clears the pending
  /// record. Returns a [Future] that resolves once cleanup is complete.
  Future<void> cancel() async {
    if (_isTerminal(_state.status)) {
      throw StateError(
          'Cannot cancel: task is already in terminal state ${_state.status}');
    }

    _setStatus(UploadTaskStatus.cancelled);
    _cancelToken?.abort();
    _cancelToken = null;

    await reference.api.deleteFile(reference.path);

    _setProgress(0.0);
    _completeTask(null);
  }

  bool _isTerminal(UploadTaskStatus s) =>
      s == UploadTaskStatus.complete ||
      s == UploadTaskStatus.failed ||
      s == UploadTaskStatus.cancelled;

  Future<void> _handleFailure(Object e, StackTrace st) async {
    _setStatus(UploadTaskStatus.failed);
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(e, st);
    }
    _closeStreams();
  }

  /// Populates the file cache for a `cache: true` upload by invoking the finalize
  /// hook — which moves the staged copy into the id-keyed cache, or records a
  /// deferred entry when no staged copy survives (e.g. a resumed transfer whose
  /// staging was lost). Runs *before* the task completes, so `whenDone` resolves
  /// only once the pin is committed. Fully guarded: a caching failure must never
  /// fail the upload. No-op when no pin hooks were supplied (a non-pinned upload).
  ///
  /// Records the committed path in [_pinnedPath], which is what the completed
  /// snapshot reports as this device's cache state. Left null on every path that
  /// did not land bytes here, so the snapshot can never over-claim.
  Future<void> _settlePin(FileData confirmed) async {
    final finalize = _onPinFinalize;
    final defer = _onPinDeferred;
    try {
      if (finalize != null) {
        _pinnedPath = await finalize(confirmed);
        return;
      }
    } catch (_) {
      // fall through to the deferred path
    }
    if (defer != null) {
      try {
        await defer(confirmed);
      } catch (_) {
        // best-effort; nothing more we can do
      }
    }
  }

  /// Settles `whenDone` with the server record, annotated with the cached copy
  /// this upload committed — so a `cache: true` upload hands back a snapshot
  /// whose `localPath` opens, without a follow-up `getSnapshot()`.
  void _completeTask(FileData? record) {
    if (!_taskCompleter.isCompleted) {
      final pinned = _pinnedPath;
      _taskCompleter.complete(record != null
          ? FileSnapshot.fromData(
              record,
              reference: reference,
              isCached: pinned != null,
              localPath: pinned,
            )
          : null);
    }
    _closeStreams();
  }

  void _closeStreams() {
    if (!_stateController.isClosed) _stateController.close();
  }

  void _setStatus(UploadTaskStatus newStatus) {
    if (_state.status == newStatus) return;
    _state = _state.withStatus(newStatus);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  void _setProgress(double newProgress) {
    final clamped = newProgress.clamp(0.0, 1.0);
    if (_state.progress == clamped) return;
    _state = _state.withProgress(clamped);
    if (!_stateController.isClosed) _stateController.add(_state);
  }
}

/// Private self-driving upload task. Starts immediately and retries via [_runUnmanaged].
class _DirectUploadTask extends UploadTask {
  _DirectUploadTask._({
    required super.reference,
    super.localPath,
    super.bytes,
    required super.mimeType,
    required super.metadata,
    required super.multipartThreshold,
    required super.maxRetries,
    required super.retryBaseDelay,
    required super.httpClient,
    super.stageSource,
    super.onPinFinalize,
    super.onPinDeferred,
  }) : super._(initialStatus: UploadTaskStatus.running);

  Future<void> _runUnmanaged() async {
    _setStatus(UploadTaskStatus.running);
    _cancelToken = TransferAbort();
    try {
      final confirmed = await _attemptOnce();
      _setProgress(1.0);
      _setStatus(UploadTaskStatus.complete);
      _completeTask(confirmed);
    } on WincheHttpException catch (e, st) {
      if (isTransferAborted(e)) return;
      await _handleFailure(e, st);
    } catch (e, st) {
      await _handleFailure(e, st);
    }
  }

  @override
  void resume() {
    if (_state.status != UploadTaskStatus.paused) {
      throw StateError(
          'Cannot resume: task is ${_state.status} (expected paused)');
    }
    unawaited(_runUnmanaged());
  }

  @override
  void abortForClose() {
    if (_isTerminal(_state.status)) return;
    _abortInFlight();
    _setStatus(UploadTaskStatus.cancelled);
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(
          const StorageCancelledException('WincheStorage was closed.'));
    }
    _closeStreams();
  }
}

/// Controller-driven upload task. Starts [UploadTaskStatus.queued] and does
/// NOT auto-run. The controller drives attempts via [runOnce].
class ManagedUploadTask extends UploadTask implements ManagedTransfer {
  ManagedUploadTask({
    required super.reference,
    super.localPath,
    super.bytes,
    required super.mimeType,
    super.metadata,
    required super.multipartThreshold,
    WincheHttp? httpClient,
    super.stageSource,
    super.onPinFinalize,
    super.onPinDeferred,
  }) : super._(
          maxRetries: 0,
          retryBaseDelay: const Duration(seconds: 1),
          httpClient: httpClient ?? defaultTransferHttp,
          initialStatus: UploadTaskStatus.queued,
        );

  /// Invoked by [resume] so the controller re-drives the same handle.
  /// Set by the controller.
  @override
  void Function()? onResume;

  /// Awaited just before this task completes. Set by the controller.
  @override
  Future<void> Function()? onBeforeComplete;

  /// Runs [onBeforeComplete], swallowing its failure: the upload has already
  /// succeeded on the server, and losing that outcome over a bookkeeping error
  /// would be worse than a stale queue entry.
  Future<void> _settleBeforeComplete() async {
    final hook = onBeforeComplete;
    if (hook == null) return;
    try {
      await hook();
    } catch (_) {
      // best-effort; the drive loop reconciles the record either way
    }
  }

  @override
  ManagedTransferState get transferState => switch (_state.status) {
        UploadTaskStatus.queued => ManagedTransferState.queued,
        UploadTaskStatus.running => ManagedTransferState.running,
        UploadTaskStatus.paused => ManagedTransferState.paused,
        UploadTaskStatus.complete => ManagedTransferState.complete,
        UploadTaskStatus.failed => ManagedTransferState.failed,
        UploadTaskStatus.cancelled => ManagedTransferState.cancelled,
      };

  @override
  void abortForClose() {
    if (_isTerminal(_state.status)) return;
    _abortInFlight();
    // Back to `queued`, not `paused`: the durable record is flipped to pending
    // by the controller and this handle resumes on the next launch. A terminal
    // status here would settle `whenDone` for a transfer that is still owed.
    _setStatus(UploadTaskStatus.queued);
  }

  /// One managed attempt: success completes the task; failure returns to
  /// [UploadTaskStatus.queued] and rethrows without completing `whenDone`.
  @override
  Future<void> runOnce() async {
    _setStatus(UploadTaskStatus.running);
    _cancelToken = TransferAbort();
    try {
      final confirmed = await _attemptOnce();
      _setProgress(1.0);
      _setStatus(UploadTaskStatus.complete);
      // The pin (via onPinFinalize) and now the durable record are both settled
      // before `whenDone` resolves, so a completed upload has fully landed.
      await _settleBeforeComplete();
      _completeTask(confirmed);
    } catch (e) {
      if (isTransferAborted(e)) return;
      _setStatus(UploadTaskStatus.queued);
      rethrow;
    }
  }

  /// Terminal failure (managed mode): retries exhausted / non-retryable. Sets
  /// [UploadTaskStatus.failed] and errors `whenDone`.
  @override
  void failPermanently(Object error, [StackTrace? st]) {
    _setStatus(UploadTaskStatus.failed);
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(error, st);
    }
    _closeStreams();
  }

  @override
  void resume() {
    if (_state.status != UploadTaskStatus.paused) {
      throw StateError(
          'Cannot resume: task is ${_state.status} (expected paused)');
    }
    _setStatus(UploadTaskStatus.queued);
    onResume?.call();
  }
}
