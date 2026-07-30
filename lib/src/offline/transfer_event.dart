import 'transfer_record.dart';

/// Which direction a [TransferEvent] describes.
///
/// Lives here rather than on [TransferRecord]: the durable queue holds uploads
/// only, so a record's direction would always be `upload`. Events cover both,
/// because downloads stay observable even though they are not persisted.
enum TransferKind { upload, download }

enum TransferEventType {
  started,
  completed,
  failed,
  retrying,

  /// The upload halted on an expired token or an unreachable server. Its record
  /// and handle survive; it resumes on the next backstop poll or on
  /// `WincheStorage.resumeUploads()`.
  ///
  /// Uploads only. A download's user-driven `pause()` is visible on the task's
  /// own `stateStream` — emitting it here would give one event type two
  /// unrelated meanings.
  paused,
}

/// Lifecycle event for a transfer in either direction.
///
/// Emitted by the durable queue for uploads and by the live task registry for
/// one-shot transfers, so every transfer is observable here — including ones
/// started without `enqueue:`. Per-byte progress stays on the task's own state
/// stream.
class TransferEvent {
  final TransferEventType type;
  final TransferKind kind;
  final String path;
  final Object? error;

  /// The durable record, on a terminal [TransferEventType.failed] — the point at
  /// which it is dropped from the queue. A path and an error are not enough to
  /// re-enqueue a lost upload: the source `localPath`, `mimeType` and `metadata`
  /// go with the record. Null on every other event type.
  ///
  /// Always null for a download: nothing is persisted for one, and a failed
  /// download loses no data, so there is nothing to hand back.
  final TransferRecord? record;

  const TransferEvent({
    required this.type,
    required this.kind,
    required this.path,
    this.error,
    this.record,
  });
}

/// Tunables for the auto-resume retry driver.
class TransferRetryConfig {
  final Duration baseDelay;
  final Duration maxDelay;
  final int maxAttempts;
  final Duration pollInterval;

  const TransferRetryConfig({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.maxAttempts = 5,
    this.pollInterval = const Duration(seconds: 30),
  });
}
