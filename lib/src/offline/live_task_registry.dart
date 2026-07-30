import '../tasks/download_task.dart';
import '../tasks/upload_task.dart';
import 'transfer_event.dart';

/// Tracks live transfers that the durable queue does not: every download, and
/// any upload started without `enqueue:`.
///
/// Two jobs, which used to be one:
///
/// * **Teardown.** Left running past `close()` a task would keep writing bytes
///   to the caller's chosen destination after the SDK was torn down — and,
///   during a user switch, under the wrong identity.
/// * **Observability.** Keyed by path and emitting [TransferEvent]s, so a
///   caller that lost its task reference can find it again, and so
///   `transferEvents` covers every transfer rather than only durable uploads.
///
/// Entries prune themselves when their task settles, so a long-lived client
/// does not accumulate completed handles.
class LiveTaskRegistry {
  LiveTaskRegistry({this.onEvent});

  /// Emits lifecycle events for the tasks tracked here. Wired by the facade to
  /// the same stream the durable queue publishes to.
  final void Function(TransferEvent event)? onEvent;

  final Map<String, UploadTask> _uploads = {};
  final Map<String, DownloadTask> _downloads = {};

  /// Live one-shot transfers currently tracked. Test seam.
  int get length => _uploads.length + _downloads.length;

  UploadTask addUpload(String path, UploadTask task) {
    _uploads[path] = task;
    _emit(TransferEventType.started, TransferKind.upload, path);
    // `.ignore()` on the pruning chain only: the caller still observes success
    // or failure on their own reference to `whenDone`.
    task.whenDone.then(
      (_) {
        if (identical(_uploads[path], task)) _uploads.remove(path);
        _emit(TransferEventType.completed, TransferKind.upload, path);
      },
      onError: (Object e) {
        if (identical(_uploads[path], task)) _uploads.remove(path);
        _emit(TransferEventType.failed, TransferKind.upload, path, e);
      },
    ).ignore();
    return task;
  }

  DownloadTask addDownload(String path, DownloadTask task) {
    _downloads[path] = task;
    _emit(TransferEventType.started, TransferKind.download, path);
    task.whenDone.then(
      (_) {
        if (identical(_downloads[path], task)) _downloads.remove(path);
        _emit(TransferEventType.completed, TransferKind.download, path);
      },
      onError: (Object e) {
        if (identical(_downloads[path], task)) _downloads.remove(path);
        _emit(TransferEventType.failed, TransferKind.download, path, e);
      },
    ).ignore();
    return task;
  }

  /// The live one-shot upload for [path], or null when none is in flight.
  UploadTask? uploadFor(String path) => _uploads[path];

  /// The live download for [path], or null when none is in flight.
  ///
  /// In-memory only, unlike the durable `uploadFor`: a download that did not
  /// survive the process is not running, so there is nothing to reattach to.
  DownloadTask? downloadFor(String path) => _downloads[path];

  /// Aborts every tracked task, settling each with `StorageCancelledException`.
  /// The error is consumed here so a caller who never awaited `whenDone` does
  /// not get an unhandled async error; a caller who did still receives it.
  void abortAll() {
    for (final t in [..._uploads.values]) {
      t.abortForClose();
      t.whenDone.ignore();
    }
    for (final t in [..._downloads.values]) {
      t.abortForClose();
      t.whenDone.ignore();
    }
    _uploads.clear();
    _downloads.clear();
  }

  /// [TransferEventType.paused] is deliberately never emitted here. It means
  /// "the durable queue halted on an expired token or a dead network"; a
  /// user-driven `pause()` on a task is visible on that task's own
  /// `stateStream`, and reusing the event type would give it two meanings.
  void _emit(TransferEventType type, TransferKind kind, String path,
      [Object? error]) {
    onEvent?.call(
        TransferEvent(type: type, kind: kind, path: path, error: error));
  }
}
