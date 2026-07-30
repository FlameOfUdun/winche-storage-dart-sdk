import 'package:winche_core/winche_core.dart';

/// Semantic error statuses for Winche Storage, mapped from HTTP/transport failures.
enum StorageErrorStatus {
  notFound,
  permissionDenied,
  unauthenticated,
  invalidArgument,
  failedPrecondition,
  deadlineExceeded,
  unavailable,
  cancelled,
  internal,
  unknown,
}

/// Base exception for every failure this package's backend reports.
///
/// Sits one level under core's [WincheException], the root for the whole
/// Winche stack. That is the intended shape: `on WincheException` asks "did
/// any Winche SDK fail?", while `on WincheStorageException` asks the narrower
/// and usually more useful "did the *storage backend* reject this?" — a
/// question a client-side lifecycle failure like [WincheUnboundException]
/// should not answer yes to.
sealed class WincheStorageException extends WincheException {
  final StorageErrorStatus status;
  final Map<String, Object?>? details;

  const WincheStorageException(this.status, super.message, [this.details]);

  /// Returns the most specific subclass for [status].
  factory WincheStorageException.fromStatus(
    StorageErrorStatus status,
    String message, [
    Map<String, Object?>? details,
  ]) {
    return switch (status) {
      StorageErrorStatus.notFound => StorageNotFoundException(message, details),
      StorageErrorStatus.permissionDenied =>
        StoragePermissionDeniedException(message, details),
      StorageErrorStatus.unauthenticated =>
        StorageUnauthenticatedException(message, details),
      StorageErrorStatus.invalidArgument =>
        StorageInvalidArgumentException(message, details),
      StorageErrorStatus.failedPrecondition =>
        StorageFailedPreconditionException(message, details),
      StorageErrorStatus.deadlineExceeded =>
        StorageDeadlineExceededException(message, details),
      StorageErrorStatus.unavailable =>
        StorageUnavailableException(message, details),
      StorageErrorStatus.cancelled =>
        StorageCancelledException(message, details),
      StorageErrorStatus.internal => StorageInternalException(message, details),
      StorageErrorStatus.unknown => StorageUnknownException(message, details),
    };
  }

  /// The originating HTTP status code, when known (carried in [details]).
  int? get statusCode => details?['statusCode'] as int?;

  @override
  String toString() => '$runtimeType($status): $message';
}

final class StorageNotFoundException extends WincheStorageException {
  const StorageNotFoundException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.notFound, message, details);
}

final class StoragePermissionDeniedException extends WincheStorageException {
  const StoragePermissionDeniedException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.permissionDenied, message, details);
}

final class StorageUnauthenticatedException extends WincheStorageException {
  const StorageUnauthenticatedException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.unauthenticated, message, details);
}

final class StorageInvalidArgumentException extends WincheStorageException {
  const StorageInvalidArgumentException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.invalidArgument, message, details);
}

final class StorageFailedPreconditionException extends WincheStorageException {
  const StorageFailedPreconditionException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.failedPrecondition, message, details);
}

final class StorageDeadlineExceededException extends WincheStorageException {
  const StorageDeadlineExceededException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.deadlineExceeded, message, details);
}

final class StorageUnavailableException extends WincheStorageException {
  const StorageUnavailableException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.unavailable, message, details);
}

final class StorageCancelledException extends WincheStorageException {
  const StorageCancelledException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.cancelled, message, details);
}

final class StorageInternalException extends WincheStorageException {
  const StorageInternalException(String message,
      [Map<String, Object?>? details])
      : super(StorageErrorStatus.internal, message, details);
}

final class StorageUnknownException extends WincheStorageException {
  const StorageUnknownException(String message, [Map<String, Object?>? details])
      : super(StorageErrorStatus.unknown, message, details);
}
