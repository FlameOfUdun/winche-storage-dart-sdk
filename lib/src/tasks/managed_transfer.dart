/// Lifecycle state shared by managed uploads and downloads. `UploadTaskStatus`
/// and `DownloadTaskStatus` carry the same members but are distinct types, which
/// forced the transfer controller to keep two copies of one drive loop.
enum ManagedTransferState { queued, running, paused, complete, failed, cancelled }

/// The controller-facing contract of a managed (durable) transfer handle.
///
/// Deliberately narrower than [UploadTask] / [DownloadTask]: the controller
/// drives attempts and decides outcomes, and everything it needs to do that is
/// here. Notably absent is `cancel()`, which for an upload deletes the remote
/// file — never the right move when the controller is merely standing down.
abstract interface class ManagedTransfer {
  /// One attempt. Success completes the handle; failure returns it to
  /// [ManagedTransferState.queued] and rethrows *without* settling `whenDone`,
  /// so the controller can retry the same handle.
  Future<void> runOnce();

  /// This handle's lifecycle state, normalized across kinds.
  ManagedTransferState get transferState;

  /// Terminal failure: settles `whenDone` with [error].
  void failPermanently(Object error, [StackTrace? st]);

  /// Aborts an in-flight attempt because the SDK is closing. Cancels in-flight
  /// HTTP and returns the handle to [ManagedTransferState.queued] without a
  /// terminal outcome — the durable record survives and resumes next session.
  void abortForClose();

  /// Resolves on the terminal outcome, across retries and restarts.
  Future<void> get whenDone;

  /// Invoked when a paused handle is resumed, so the controller re-enters its
  /// drive loop rather than letting the handle self-drive.
  abstract void Function()? onResume;

  /// Awaited immediately before the handle completes, so the controller's
  /// bookkeeping — dropping the durable record, emitting `completed` — is
  /// already done by the time `whenDone` resolves.
  ///
  /// Without it the record is removed just *after* `runOnce` returns, so
  /// `await task.whenDone` followed by `pendingTransfers()` could still see the
  /// finished transfer. Same contract as the pinned upload's `onPinFinalize`:
  /// a completed transfer has fully landed.
  abstract Future<void> Function()? onBeforeComplete;
}
