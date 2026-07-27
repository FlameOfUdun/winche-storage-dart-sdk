import '../api/winche_storage_exception.dart';

/// How the transfer controller should react to a failed attempt.
enum TransferFailureClass {
  /// The condition is outside the transfer's control and will clear on its own —
  /// an expired token, or no network. The durable record is left untouched (the
  /// attempt is *not* counted) and the handle stays alive, so no amount of
  /// waiting can destroy queued work.
  pause,

  /// Possibly transient. Count an attempt, back off, and give up once
  /// `retryMaxAttempts` is exhausted.
  retry,

  /// This transfer can never succeed as specified. Drop it and report the
  /// record so the caller can re-enqueue.
  terminal,
}

/// Classifies a failed transfer attempt.
///
/// The split exists because a single "count an attempt, then give up" policy
/// destroys durable work: an expired token or a flat network would burn
/// `retryMaxAttempts` in a couple of minutes and drop an upload the user still
/// expects to happen.
///
/// Errors that are not [WincheStorageException] — a missing source file, a
/// serialization bug — classify as [TransferFailureClass.retry]. Some of them
/// are permanent, but the attempt cap reaches the same end state without having
/// to enumerate every possibility, and misclassifying a genuinely transient one
/// as terminal would lose work.
TransferFailureClass classifyTransferFailure(Object error) {
  if (error is! WincheStorageException) return TransferFailureClass.retry;
  return switch (error.status) {
    // Clears when the token is refreshed or the network returns.
    StorageErrorStatus.unauthenticated ||
    StorageErrorStatus.unavailable =>
      TransferFailureClass.pause,

    // The request itself is rejected; repeating it verbatim cannot help.
    StorageErrorStatus.permissionDenied ||
    StorageErrorStatus.notFound ||
    StorageErrorStatus.invalidArgument ||
    StorageErrorStatus.failedPrecondition =>
      TransferFailureClass.terminal,

    // Server-side or ambiguous — worth a bounded number of retries.
    StorageErrorStatus.internal ||
    StorageErrorStatus.deadlineExceeded ||
    StorageErrorStatus.cancelled ||
    StorageErrorStatus.unknown =>
      TransferFailureClass.retry,
  };
}
