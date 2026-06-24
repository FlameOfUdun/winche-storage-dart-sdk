import 'transfer_record.dart';

enum TransferEventType { started, completed, failed, retrying }

/// Lifecycle event emitted by [TransferController] as the queue drains.
/// Per-byte progress is observed on the returned task's own state stream.
class TransferEvent {
  final TransferEventType type;
  final TransferKind kind;
  final String path;
  final Object? error;

  const TransferEvent({
    required this.type,
    required this.kind,
    required this.path,
    this.error,
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
