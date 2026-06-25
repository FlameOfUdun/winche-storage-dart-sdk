import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../child_reference.dart';
import '../file_snapshot.dart';
import '../models/file_data.dart';
import '../models/upload_status.dart';

enum UploadTaskStatus {
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

final class UploadTask {
  final ChildReference reference;
  final String? localPath;
  final Uint8List? bytes;
  final String mimeType;
  final Map<String, dynamic>? metadata;
  final int multipartThreshold;
  final int maxRetries;
  final Duration retryBaseDelay;
  final Dio _httpClient;
  final Future<String> Function()? _stageSource;
  final Future<void> Function(FileData confirmed)? _onPinFinalize;
  final Future<void> Function(FileData confirmed)? _onPinDeferred;

  /// Set once a stage succeeds; guards against re-staging on pause/resume.
  String? _stagedPath;

  final _stateController = StreamController<UploadTaskState>.broadcast();
  final _taskCompleter = Completer<FileSnapshot?>();

  CancelToken? _cancelToken;
  UploadTaskState _state =
      const UploadTaskState(status: UploadTaskStatus.running, progress: 0.0);

  UploadTaskState get state => _state;
  Stream<UploadTaskState> get stateStream => _stateController.stream;
  Future<FileSnapshot?> get whenDone => _taskCompleter.future;

  UploadTask._({
    required this.reference,
    this.localPath,
    this.bytes,
    required this.mimeType,
    required this.metadata,
    required this.multipartThreshold,
    required this.maxRetries,
    required this.retryBaseDelay,
    required Dio httpClient,
    Future<String> Function()? stageSource,
    Future<void> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  })  : _httpClient = httpClient,
        _stageSource = stageSource,
        _onPinFinalize = onPinFinalize,
        _onPinDeferred = onPinDeferred;

  /// Creates and immediately starts an [UploadTask] from a local file path.
  ///
  /// [httpClient] should be a shared [Dio] instance configured by the caller.
  /// If omitted, a private instance is created (note: it will not be disposed
  /// by this task — prefer passing a shared one).
  factory UploadTask.start({
    required ChildReference reference,
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(seconds: 1),
    Dio? httpClient,
    Future<String> Function()? stageSource,
    Future<void> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  }) {
    final client = httpClient ??
        Dio(BaseOptions(
          validateStatus: (status) => status != null,
        ));

    final task = UploadTask._(
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

    unawaited(task._run());
    return task;
  }

  /// Creates and immediately starts an [UploadTask] from raw bytes.
  ///
  /// [httpClient] should be a shared [Dio] instance configured by the caller.
  /// If omitted, a private instance is created (note: it will not be disposed
  /// by this task — prefer passing a shared one).
  factory UploadTask.startFromBytes({
    required ChildReference reference,
    required Uint8List bytes,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(seconds: 1),
    Dio? httpClient,
    Future<String> Function()? stageSource,
    Future<void> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  }) {
    final client = httpClient ??
        Dio(BaseOptions(
          validateStatus: (status) => status != null,
        ));

    final task = UploadTask._(
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

    unawaited(task._run());
    return task;
  }

  Future<void> _run() async {
    _setStatus(UploadTaskStatus.running);
    _cancelToken = CancelToken();

    try {
      // Pin-on-upload: stage a safe local copy and upload *from* it, so the
      // upload no longer depends on the caller's original file. Best-effort —
      // on staging failure we upload from the original source and mark the pin
      // deferred after confirm.
      String? effPath = localPath;
      Uint8List? effBytes = bytes;
      if (_stageSource != null) {
        if (_stagedPath == null) {
          try {
            _stagedPath = await _stageSource!();
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
            _setProgress(1.0);
            _setStatus(UploadTaskStatus.complete);
            _completeTask(existingRecord);
            return;
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
      _setProgress(1.0);
      _setStatus(UploadTaskStatus.complete);
      _completeTask(confirmed);
    } on DioException catch (e, st) {
      if (e.type == DioExceptionType.cancel) return;
      await _handleFailure(e, st);
    } catch (e, st) {
      await _handleFailure(e, st);
    }
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
        final Stream<List<int>> body =
            bytes != null ? Stream.value(bytes) : localFile!.openRead();

        final response = await _httpClient.put<void>(
          session.url,
          data: body,
          options: Options(
            contentType: mimeType,
            headers: {
              'Content-Length': sizeBytes.toString(),
            },
          ),
          cancelToken: _cancelToken,
          onSendProgress: (sent, _) {
            if (sizeBytes > 0) _setProgress(sent / sizeBytes);
          },
        );

        final code = response.statusCode;
        if (code != 200 && code != 201) {
          throw Exception('Failed to upload file: HTTP $code');
        }
        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;

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
        final Stream<List<int>> chunk;
        if (bytes != null) {
          chunk =
              Stream.value(bytes.sublist(byteOffset, byteOffset + chunkSize));
        } else {
          chunk = localFile!.openRead(byteOffset, byteOffset + chunkSize);
        }

        final response = await _httpClient.put<void>(
          session.url,
          data: chunk,
          options: Options(
            contentType: mimeType,
            headers: {
              'Content-Length': chunkSize.toString(),
            },
          ),
          cancelToken: _cancelToken,
          onSendProgress: (sent, _) {
            final overallProgress = (byteOffset + sent) / sizeBytes;
            _setProgress(overallProgress);
          },
        );

        final code = response.statusCode;
        if (code != 200 && code != 201) {
          throw Exception('Failed to upload part $partNumber: HTTP $code');
        }
        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;

        final isLastAttempt = attempt == maxRetries;
        if (isLastAttempt) rethrow;

        final delay = retryBaseDelay * (1 << attempt);
        await Future<void>.delayed(delay);
        if (!_isRunning) return;
      }
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
    _cancelToken?.cancel('paused');
    _cancelToken = null;
  }

  /// Resumes a paused upload.
  void resume() {
    if (_state.status != UploadTaskStatus.paused) {
      throw StateError(
          'Cannot resume: task is ${_state.status} (expected paused)');
    }
    unawaited(_run());
  }

  /// Cancels the upload, deletes the remote file, and clears the pending
  /// record. Returns a [Future] that resolves once cleanup is complete.
  Future<void> cancel() async {
    if (_isTerminal(_state.status)) {
      throw StateError(
          'Cannot cancel: task is already in terminal state ${_state.status}');
    }

    _setStatus(UploadTaskStatus.cancelled);
    _cancelToken?.cancel('cancelled');
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

  /// Populates the offline cache for a pinned upload. Fully guarded: a caching
  /// failure must never fail the upload. No-op when this isn't a pinned upload
  /// (i.e. [_stageSource] is null) or when no settle hooks were supplied (the
  /// controller path, which finalizes pins itself).
  Future<void> _settlePin(FileData confirmed) async {
    if (_stageSource == null) return;
    final finalize = _onPinFinalize;
    final defer = _onPinDeferred;
    try {
      if (_stagedPath != null && finalize != null) {
        await finalize(confirmed);
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

  void _completeTask(FileData? record) {
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.complete(record != null
          ? FileSnapshot.fromData(record, reference: reference)
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
