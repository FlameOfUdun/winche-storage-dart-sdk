import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../child_reference.dart';

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
  final Dio _httpClient;

  final _stateController = StreamController<DownloadTaskState>.broadcast();
  final _taskCompleter = Completer<void>();

  CancelToken? _cancelToken;
  DownloadTaskState _state;

  DownloadTaskState get state => _state;
  Stream<DownloadTaskState> get stateStream => _stateController.stream;
  Future<void> get whenDone => _taskCompleter.future;

  DownloadTask._({
    required this.reference,
    required this.saveTo,
    required this.maxRetries,
    required this.retryBaseDelay,
    required Dio httpClient,
    required DownloadTaskStatus initialStatus,
  })  : _httpClient = httpClient,
        _state = DownloadTaskState(status: initialStatus);

  factory DownloadTask.start({
    required ChildReference reference,
    required String saveTo,
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(seconds: 1),
    Dio? httpClient,
  }) {
    final client = httpClient ??
        Dio(BaseOptions(validateStatus: (status) => status != null));

    final task = _DirectDownloadTask._(
      reference: reference,
      saveTo: saveTo,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      httpClient: client,
    );

    unawaited(task._run());
    return task;
  }

  Future<void> _attempt({bool isResume = false}) async {
    final session = await reference.api.generateDownloadUrl(reference.path);
    final file = File(saveTo);

    final existingBytes =
        isResume && await file.exists() ? await file.length() : 0;

    final headers = existingBytes > 0
        ? <String, dynamic>{'Range': 'bytes=$existingBytes-'}
        : <String, dynamic>{};

    final response = await _httpClient.get<ResponseBody>(
      session.url,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        validateStatus: (s) => s != null,
      ),
      cancelToken: _cancelToken,
    );

    final code = response.statusCode ?? 0;

    if (code == 416) {
      final record = await reference.api.getFile(reference.path);
      if (record != null && existingBytes >= record.sizeBytes) {
        _setProgress(1.0);
        _setStatus(DownloadTaskStatus.complete);
        _completeTask();
        return;
      }
      throw Exception(
          'Range not satisfiable (HTTP 416) for "${reference.path}"');
    }

    if (code != 200 && code != 206) {
      throw Exception('Download failed: HTTP $code');
    }

    final contentLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        ) ??
        -1;

    final isPartial = code == 206;

    final totalBytes = isPartial
        ? (contentLength >= 0 ? existingBytes + contentLength : -1)
        : contentLength;

    final writeMode = isPartial ? FileMode.append : FileMode.write;
    var bytesWritten = isPartial ? existingBytes : 0;

    if (totalBytes > 0 && bytesWritten > 0) {
      _setProgress(bytesWritten / totalBytes);
    }

    final body = response.data as ResponseBody;
    final sink = await file.open(mode: writeMode);

    try {
      await for (final chunk in body.stream) {
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

  /// Pauses the download mid-flight.
  void pause() {
    if (_state.status != DownloadTaskStatus.running) {
      throw StateError(
          'Cannot pause: task is ${_state.status} (expected running)');
    }
    _setStatus(DownloadTaskStatus.paused);

    _cancelToken?.cancel('paused');
    _cancelToken = null;
  }

  /// Resumes a [DownloadTaskStatus.paused] download.
  void resume();

  /// Cancels the download and deletes any partially written file.
  void cancel() async {
    if (_isTerminal(_state.status)) {
      throw StateError(
          'Cannot cancel: task is already in terminal state ${_state.status}');
    }
    _setStatus(DownloadTaskStatus.cancelled);

    _cancelToken?.cancel('cancelled');
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
  }) : super._(initialStatus: DownloadTaskStatus.running);

  Future<void> _run({bool isResume = false}) async {
    _setStatus(DownloadTaskStatus.running);
    _cancelToken = CancelToken();

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        await _attempt(isResume: isResume);
        return;
      } on DioException catch (e, st) {
        if (e.type == DioExceptionType.cancel) return;
        if (!_isRunning) return;

        if (attempt == maxRetries) {
          await _handleFailure(e, st);
          return;
        }

        final delay = retryBaseDelay * (1 << attempt);
        await Future<void>.delayed(delay);
        if (!_isRunning) return;
        _cancelToken = CancelToken();
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
}

/// Controller-driven download task. Starts [DownloadTaskStatus.queued] and does
/// NOT auto-run. The controller drives attempts via [runOnce].
class ManagedDownloadTask extends DownloadTask {
  ManagedDownloadTask({
    required super.reference,
    required super.saveTo,
    Dio? httpClient,
  }) : super._(
          maxRetries: 0,
          retryBaseDelay: const Duration(seconds: 1),
          httpClient: httpClient ??
              Dio(BaseOptions(validateStatus: (status) => status != null)),
          initialStatus: DownloadTaskStatus.queued,
        );

  /// Invoked by [resume] so the controller re-drives the same handle.
  /// Set by the controller.
  void Function()? onResume;

  /// Runs exactly one attempt (managed mode). On success the task completes
  /// ([DownloadTaskStatus.complete], `whenDone` resolves). On failure it returns
  /// to [DownloadTaskStatus.queued] and rethrows WITHOUT completing `whenDone`,
  /// so the controller can retry the same handle or call [failPermanently].
  Future<void> runOnce({bool isResume = false}) async {
    _setStatus(DownloadTaskStatus.running);
    _cancelToken = CancelToken();
    try {
      await _attempt(isResume: isResume);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      _setStatus(DownloadTaskStatus.queued);
      rethrow;
    }
  }

  /// Terminal failure (managed mode): retries exhausted / non-retryable. Sets
  /// [DownloadTaskStatus.failed] and errors `whenDone`.
  void failPermanently(Object error, [StackTrace? st]) {
    _setStatus(DownloadTaskStatus.failed);
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(error, st);
    }
    _closeStreams();
  }

  @override
  void resume() {
    if (_state.status != DownloadTaskStatus.paused) {
      throw StateError(
          'Cannot resume: task is ${_state.status} (expected paused)');
    }
    _setStatus(DownloadTaskStatus.queued);
    onResume?.call();
  }
}
