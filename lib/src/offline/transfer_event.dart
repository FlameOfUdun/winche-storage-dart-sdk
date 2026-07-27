import 'transfer_record.dart';

enum TransferEventType {
  started,
  completed,
  failed,
  retrying,

  /// The transfer halted on an expired token or an unreachable server. Its
  /// record and handle survive; it resumes on the next backstop poll or on
  /// `WincheStorage.resumeTransfers()`.
  paused,
}

/// Lifecycle event emitted by [TransferController] as the queue drains.
/// Per-byte progress is observed on the returned task's own state stream.
class TransferEvent {
  final TransferEventType type;
  final TransferKind kind;
  final String path;
  final Object? error;

  /// The durable record, on a terminal [TransferEventType.failed] — the point at
  /// which it is dropped from the queue. A path and an error are not enough to
  /// re-enqueue a lost upload: the source `localPath`, `mimeType` and `metadata`
  /// go with the record. Null on every other event type.
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
