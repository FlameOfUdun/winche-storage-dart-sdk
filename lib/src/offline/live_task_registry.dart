import '../tasks/download_task.dart';
import '../tasks/upload_task.dart';

/// Tracks live **one-shot** transfers — the ones started without `enqueue:`, so
/// nothing durable records them — so `WincheStorage.close()` can abort them.
///
/// Managed transfers need no registry: the controller already holds them, and
/// their durable record lets them resume later. A one-shot has neither. Left
/// running past `close()` it would keep writing bytes to the caller's chosen
/// destination after the SDK was torn down — and, during a user switch, under
/// the wrong identity.
///
/// Entries prune themselves when their task settles, so a long-lived client does
/// not accumulate completed handles.
class LiveTaskRegistry {
  final Set<UploadTask> _uploads = {};
  final Set<DownloadTask> _downloads = {};

  /// Live one-shot transfers currently tracked. Test seam.
  int get length => _uploads.length + _downloads.length;

  UploadTask addUpload(UploadTask task) {
    _uploads.add(task);
    // `.ignore()` on the pruning chain only: the caller still observes success
    // or failure on their own reference to `whenDone`.
    task.whenDone.whenComplete(() => _uploads.remove(task)).ignore();
    return task;
  }

  DownloadTask addDownload(DownloadTask task) {
    _downloads.add(task);
    task.whenDone.whenComplete(() => _downloads.remove(task)).ignore();
    return task;
  }

  /// Aborts every tracked task, settling each with `StorageCancelledException`.
  /// The error is consumed here so a caller who never awaited `whenDone` does
  /// not get an unhandled async error; a caller who did still receives it.
  void abortAll() {
    for (final t in [..._uploads]) {
      t.abortForClose();
      t.whenDone.ignore();
    }
    for (final t in [..._downloads]) {
      t.abortForClose();
      t.whenDone.ignore();
    }
    _uploads.clear();
    _downloads.clear();
  }
}
