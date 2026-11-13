import 'dart:async';
import 'dart:io';

import 'package:winche_core/winche_core.dart';

import '../api/winche_storage_exception.dart';
import '../child_reference.dart';
import 'transfer_http.dart';

enum DownloadTaskStatus {
  queued,
  running,
  paused,
  complete,
  failed,
  cancelled,
}

final class DownloadTaskState {
  final DownloadTaskStatus status;
  final double progress;

  const DownloadTaskState({
    this.status = DownloadTaskStatus.running,
    this.progress = 0.0,
  });

  DownloadTaskState withStatus(DownloadTaskStatus newStatus) =>
      DownloadTaskState(status: newStatus, progress: progress);
  DownloadTaskState withProgress(double newProgress) =>
      DownloadTaskState(status: status, progress: newProgress);
}

abstract class DownloadTask {
  final ChildReference reference;

  /// Absolute destination path the file is written to.
  final String saveTo;

  final int maxRetries;
  final Duration retryBaseDelay;
  final WincheHttp _httpClient;

  /// Sent as `If-Range` alongside a range request, so a server that has since
  /// overwritten the object answers with the whole body (HTTP 200) instead of
  /// a range that would be appended to a stale partial.
  ///
  /// Supplied only by cache downloads, which have a catalog row to store an
  /// ETag in. A one-shot download leaves it null and relies on its partial
  /// being deleted on any graceful failure.
  final String? ifRangeEtag;

  String? _observedEtag;

  /// The ETag the server returned for the bytes now on disk, when it sent one.
  /// Read by the cache after a successful download so the next resume can send
  /// it back as `If-Range`.
  String? get observedEtag => _observedEtag;

  final _stateController = StreamController<DownloadTaskState>.broadcast();
  final _taskCompleter = Completer<void>();

  TransferAbort? _cancelToken;
  DownloadTaskState _state;

  DownloadTaskState get state => _state;
  Stream<DownloadTaskState> get stateStream => _stateController.stream;
  Future<void> get whenDone => _taskCompleter.future;

  DownloadTask._({
    required this.reference,
    required this.saveTo,
    required this.maxRetries,
    required this.retryBaseDelay,
    required WincheHttp httpClient,
    required DownloadTaskStatus initialStatus,
    this.ifRangeEtag,
  })  : _httpClient = httpClient,
        _state = DownloadTaskState(status: initialStatus);

  /// Starts a download immediately.
  ///
  /// [isResume] continues from a partial already at [saveTo] rather than
  /// starting from zero. The caller is responsible for having established that
  /// the partial is still valid — see the cache's `contentHash` guard. Without
  /// it, a partial left by an abrupt process kill would never be picked up,
  /// since only `resume()` could previously set it.
  factory DownloadTask.start({
    required ChildReference reference,
    required String saveTo,
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(seconds: 1),
    WincheHttp? httpClient,
    bool isResume = false,
    String? ifRangeEtag,
  }) {
    final client = httpClient ?? defaultTransferHttp;

    final task = _DirectDownloadTask._(
      reference: reference,
      saveTo: saveTo,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      httpClient: client,
      ifRangeEtag: ifRangeEtag,
    );

    unawaited(task._run(isResume: isResume));
    return task;
  }

  Future<void> _attempt({bool isResume = false}) async {
    final session = await reference.api.generateDownloadUrl(reference.path);
    final file = File(saveTo);

    final existingBytes =
        isResume && await file.exists() ? await file.length() : 0;

    final headers = existingBytes > 0
        ? <String, String>{
            'Range': 'bytes=$existingBytes-',
            // Belt to the contentHash guard's braces: if the object changed,
            // the server answers 200 with the whole body and the 206/200 branch
            // below truncates instead of appending.
            if (ifRangeEtag case final etag?) 'If-Range': etag,
          }
        : <String, String>{};

    final WincheStreamedResponse response;
    try {
      response = await _httpClient.stream(WincheRequest.get(
        Uri.parse(session.url),
        headers: headers,
        auth: WincheRequestAuth.none,
        // Tries are this task's to count, with its own backoff.
        idempotent: false,
        timeout: const Duration(minutes: 2),
        abortTrigger: _cancelToken?.trigger,
        service: 'storage',
      ));
    } on WincheHttpException catch (e) {
      final status = e.status;
      if (status == null) rethrow;
      if (status != 416) throw Exception('Download failed: HTTP $status');
      await _settleUnsatisfiableRange(existingBytes);
      return;
    }

    final code = response.status;

    if (code != 200 && code != 206) {
      throw Exception('Download failed: HTTP $code');
    }

    final contentLength = response.contentLength ??
        int.tryParse(response.headers['content-length'] ?? '') ??
        -1;

    // Captured for the next resume's If-Range. Recorded before any bytes are
    // written so it always describes the body being received.
    _observedEtag = response.headers['etag'] ?? _observedEtag;

    final isPartial = code == 206;

    final totalBytes = isPartial
        ? (contentLength >= 0 ? existingBytes + contentLength : -1)
        : contentLength;

    final writeMode = isPartial ? FileMode.append : FileMode.write;
    var bytesWritten = isPartial ? existingBytes : 0;

    if (totalBytes > 0 && bytesWritten > 0) {
      _setProgress(bytesWritten / totalBytes);
    }

    final sink = await file.open(mode: writeMode);

    try {
      await for (final chunk in response.body) {
        if (!_isRunning) return;
        await sink.writeFrom(chunk);
        bytesWritten += chunk.length;
        if (totalBytes > 0) _setProgress(bytesWritten / totalBytes);
      }
    } finally {
      await sink.close();
    }

    if (!_isRunning) return;

    final record = await reference.api.getFile(reference.path);
    if (record == null) {
      throw Exception(
          'Download succeeded but remote record not found for "${reference.path}"');
    }

    if (bytesWritten != record.sizeBytes) {
      throw Exception(
          'Download size mismatch for "${reference.path}" '
          '(expected ${record.sizeBytes} B, wrote $bytesWritten B)');
    }

    _setProgress(1.0);
    _setStatus(DownloadTaskStatus.complete);
    _completeTask();
  }

  /// A 416: the partial on disk may already be the whole file.
  Future<void> _settleUnsatisfiableRange(int existingBytes) async {
    final record = await reference.api.getFile(reference.path);
    if (record != null && existingBytes >= record.sizeBytes) {
      _setProgress(1.0);
      _setStatus(DownloadTaskStatus.complete);
      _completeTask();
      return;
    }
    throw Exception('Range not satisfiable (HTTP 416) for "${reference.path}"');
  }

  /// Pauses the download mid-flight.
  void pause() {
    if (_state.status != DownloadTaskStatus.running) {
      throw StateError(
          'Cannot pause: task is ${_state.status} (expected running)');
    }
    _setStatus(DownloadTaskStatus.paused);

    _cancelToken?.abort();
    _cancelToken = null;
  }

  /// Resumes a [DownloadTaskStatus.paused] download.
  void resume();

  /// Aborts an in-flight attempt because `WincheStorage.close()` was called.
  ///
  /// Downloads are never durable, so there is no record to resume from: the
  /// task settles with [StorageCancelledException]. Any partial bytes stay on
  /// disk, and a later `keepCached()` resumes from them once it has confirmed
  /// the remote content is unchanged.
  void abortForClose();

  /// Cancels in-flight HTTP without touching status or completion. Shared by
  /// the two [abortForClose] implementations.
  void _abortInFlight() {
    _cancelToken?.abort();
    _cancelToken = null;
  }

  /// Cancels the download and deletes any partially written file.
  void cancel() async {
    if (_isTerminal(_state.status)) {
      throw StateError(
          'Cannot cancel: task is already in terminal state ${_state.status}');
    }
    _setStatus(DownloadTaskStatus.cancelled);

    _cancelToken?.abort();
    _cancelToken = null;

    _setProgress(0.0);
    _completeTask(); // complete before async cleanup so whenDone fires reliably

    await _deletePartialFile();
  }

  bool get _isRunning => _state.status == DownloadTaskStatus.running;

  bool _isTerminal(DownloadTaskStatus s) =>
      s == DownloadTaskStatus.complete ||
      s == DownloadTaskStatus.failed ||
      s == DownloadTaskStatus.cancelled;

  Future<void> _handleFailure(Object e, StackTrace st) async {
    _setStatus(DownloadTaskStatus.failed);
    // Remove the corrupt partial before reporting failure, so callers awaiting
    // whenDone never observe a leftover file.
    await _deletePartialFile();
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(e, st);
    }
    _closeStreams();
  }

  /// Best-effort deletion of the partially written destination file.
  Future<void> _deletePartialFile() async {
    try {
      final file = File(saveTo);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // best-effort cleanup — ignore if the file is locked or already gone
    }
  }

  void _completeTask() {
    if (!_taskCompleter.isCompleted) _taskCompleter.complete();
    _closeStreams();
  }

  void _closeStreams() {
    if (!_stateController.isClosed) _stateController.close();
  }

  void _setStatus(DownloadTaskStatus newStatus) {
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

/// Private self-driving download task. Starts immediately and retries via [_run].
class _DirectDownloadTask extends DownloadTask {
  _DirectDownloadTask._({
    required super.reference,
    required super.saveTo,
    required super.maxRetries,
    required super.retryBaseDelay,
    required super.httpClient,
    super.ifRangeEtag,
  }) : super._(initialStatus: DownloadTaskStatus.running);

  Future<void> _run({bool isResume = false}) async {
    _setStatus(DownloadTaskStatus.running);
    _cancelToken = TransferAbort();

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        await _attempt(isResume: isResume);
        return;
      } on WincheHttpException catch (e, st) {
        if (isTransferAborted(e)) return;
        if (!_isRunning) return;
        if (!isTransferNetworkFailure(e)) {
          await _handleFailure(e, st);
          return;
        }

        if (attempt == maxRetries) {
          await _handleFailure(e, st);
          return;
        }

        final delay = retryBaseDelay * (1 << attempt);
        await Future<void>.delayed(delay);
        if (!_isRunning) return;
        _cancelToken = TransferAbort();
      } catch (e, st) {
        if (!_isRunning) return;
        await _handleFailure(e, st);
        return;
      }
    }
  }

  @override
  void resume() {
    if (_state.status != DownloadTaskStatus.paused) {
      throw StateError(
          'Cannot resume: task is ${_state.status} (expected paused)');
    }
    unawaited(_run(isResume: true));
  }

  @override
  void abortForClose() {
    if (_isTerminal(_state.status)) return;
    _abortInFlight();
    _setStatus(DownloadTaskStatus.cancelled);
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(
          WincheStorageException.of(WincheErrorCode.cancelled, 'WincheStorage was closed.'));
    }
    _closeStreams();
  }
}

