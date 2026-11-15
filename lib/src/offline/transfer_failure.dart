import 'dart:io';

import 'package:winche_core/winche_core.dart';

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
  // A session superseded by a user switch, or ended by a sign-out. Checked
  // ahead of the fallback below, which would otherwise class it as `retry` and
  // spend the budget on a session that no longer exists — for a transfer core
  // is already tearing down.
  if (error is WincheSessionExpired) return TransferFailureClass.pause;
  // The byte transfer itself (the presigned PUT to object storage) surfaces
  // the HTTP client's own errors. A dropped or absent network there is a pause
  // like any other: counting it as a retry spent the whole budget in about a
  // minute offline and left the upload failed until the next app start. An
  // HTTP error from the bucket (an expired presigned URL is a 403) is retried:
  // the next attempt asks for a fresh upload session.
  if (error is WincheHttpException) {
    return error.status == null && error.code != WincheErrorCode.cancelled
        ? TransferFailureClass.pause
        : TransferFailureClass.retry;
  }
  if (error is SocketException) return TransferFailureClass.pause;
  if (error is! WincheStorageException) return TransferFailureClass.retry;
  return switch (error.code) {
    // Clears when the token is refreshed or the network returns.
    WincheErrorCode.unauthenticated || WincheErrorCode.unavailable => TransferFailureClass.pause,

    // The request itself is rejected; repeating it verbatim cannot help.
    WincheErrorCode.permissionDenied ||
    WincheErrorCode.notFound ||
    WincheErrorCode.invalidArgument ||
    WincheErrorCode.failedPrecondition ||
    WincheErrorCode.alreadyExists ||
    WincheErrorCode.outOfRange ||
    WincheErrorCode.unimplemented =>
      TransferFailureClass.terminal,

    // Server-side, ambiguous or a limit — worth a bounded number of retries.
    WincheErrorCode.internal ||
    WincheErrorCode.deadlineExceeded ||
    WincheErrorCode.cancelled ||
    WincheErrorCode.aborted ||
    WincheErrorCode.resourceExhausted ||
    WincheErrorCode.dataLoss ||
    WincheErrorCode.unknown =>
      TransferFailureClass.retry,
  };
}
