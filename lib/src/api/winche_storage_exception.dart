// The per-kind subclasses are deprecated for callers, but storage still throws them for one release so existing
// `on StorageNotFoundException` catches keep working.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:winche_core/winche_core.dart';

/// A storage request failed.
///
/// [code] is the kind every Winche package shares; switch on it rather than on
/// subclasses. [reason] is the server's more precise code where it sent one
/// (`too-large`, `size-mismatch`, `upload-status`, `not-uploaded`).
///
/// `on WincheException` asks "did any Winche SDK fail?"; `on
/// WincheStorageException` asks "did storage?". A [WincheUnboundException] or
/// `WincheSessionExpired` is neither: it never reached the server.
class WincheStorageException extends WincheException {
  /// Creates an exception of kind [code]. Storage itself throws through [of].
  const WincheStorageException(super.code, super.message, {this.reason, this.statusCode});

  /// The server's more precise code, when it sent one.
  final String? reason;

  /// An exception of kind [code]: for this release, the deprecated subclass
  /// for that kind when there is one, so catches on those keep working.
  factory WincheStorageException.of(WincheErrorCode code, String message, {String? reason, int? statusCode}) => switch (code) {
    WincheErrorCode.notFound => StorageNotFoundException._(message, statusCode, reason),
    WincheErrorCode.permissionDenied => StoragePermissionDeniedException._(message, statusCode, reason),
    WincheErrorCode.unauthenticated => StorageUnauthenticatedException._(message, statusCode, reason),
    WincheErrorCode.invalidArgument => StorageInvalidArgumentException._(message, statusCode, reason),
    WincheErrorCode.failedPrecondition => StorageFailedPreconditionException._(message, statusCode, reason),
    WincheErrorCode.deadlineExceeded => StorageDeadlineExceededException._(message, statusCode, reason),
    WincheErrorCode.unavailable => StorageUnavailableException._(message, statusCode, reason),
    WincheErrorCode.cancelled => StorageCancelledException._(message, statusCode, reason),
    WincheErrorCode.internal => StorageInternalException._(message, statusCode, reason),
    WincheErrorCode.unknown => StorageUnknownException._(message, statusCode, reason),
    _ => WincheStorageException(code, message, reason: reason, statusCode: statusCode),
  };

  /// The HTTP status, when there was an answer.
  final int? statusCode;

  /// The old name for [code]'s kind.
  @Deprecated('Use code (WincheErrorCode). Removed in the next major version.')
  StorageErrorStatus get status => switch (code) {
    WincheErrorCode.notFound => StorageErrorStatus.notFound,
    WincheErrorCode.permissionDenied => StorageErrorStatus.permissionDenied,
    WincheErrorCode.unauthenticated => StorageErrorStatus.unauthenticated,
    WincheErrorCode.invalidArgument => StorageErrorStatus.invalidArgument,
    WincheErrorCode.failedPrecondition => StorageErrorStatus.failedPrecondition,
    WincheErrorCode.deadlineExceeded => StorageErrorStatus.deadlineExceeded,
    WincheErrorCode.unavailable => StorageErrorStatus.unavailable,
    WincheErrorCode.cancelled => StorageErrorStatus.cancelled,
    WincheErrorCode.internal => StorageErrorStatus.internal,
    _ => StorageErrorStatus.unknown,
  };

  /// The old place for [statusCode].
  @Deprecated('Use statusCode. Removed in the next major version.')
  Map<String, Object?>? get details => statusCode == null ? null : {'statusCode': statusCode};

  /// The old way to make one.
  @Deprecated('Use WincheStorageException.of. Removed in the next major version.')
  factory WincheStorageException.fromStatus(StorageErrorStatus status, String message, [Map<String, Object?>? details]) =>
      WincheStorageException.of(status._code, message, statusCode: details?['statusCode'] as int?);

  @override
  String toString() => 'WincheStorageException(${code.wireName}${reason == null ? '' : '/$reason'}): $message';
}

/// The old kinds of storage error.
@Deprecated('Use WincheErrorCode. Removed in the next major version.')
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
  unknown;

  WincheErrorCode get _code => switch (this) {
    notFound => WincheErrorCode.notFound,
    permissionDenied => WincheErrorCode.permissionDenied,
    unauthenticated => WincheErrorCode.unauthenticated,
    invalidArgument => WincheErrorCode.invalidArgument,
    failedPrecondition => WincheErrorCode.failedPrecondition,
    deadlineExceeded => WincheErrorCode.deadlineExceeded,
    unavailable => WincheErrorCode.unavailable,
    cancelled => WincheErrorCode.cancelled,
    internal => WincheErrorCode.internal,
    unknown => WincheErrorCode.unknown,
  };
}

int? _statusOf(Map<String, Object?>? details) => details?['statusCode'] as int?;

/// Storage's `notFound`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.notFound. Removed in the next major version.')
final class StorageNotFoundException extends WincheStorageException {
  StorageNotFoundException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.notFound, message, statusCode: _statusOf(details));

  StorageNotFoundException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.notFound, message, statusCode: statusCode, reason: reason);
}

/// Storage's `permissionDenied`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.permissionDenied. Removed in the next major version.')
final class StoragePermissionDeniedException extends WincheStorageException {
  StoragePermissionDeniedException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.permissionDenied, message, statusCode: _statusOf(details));

  StoragePermissionDeniedException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.permissionDenied, message, statusCode: statusCode, reason: reason);
}

/// Storage's `unauthenticated`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.unauthenticated. Removed in the next major version.')
final class StorageUnauthenticatedException extends WincheStorageException {
  StorageUnauthenticatedException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.unauthenticated, message, statusCode: _statusOf(details));

  StorageUnauthenticatedException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.unauthenticated, message, statusCode: statusCode, reason: reason);
}

/// Storage's `invalidArgument`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.invalidArgument. Removed in the next major version.')
final class StorageInvalidArgumentException extends WincheStorageException {
  StorageInvalidArgumentException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.invalidArgument, message, statusCode: _statusOf(details));

  StorageInvalidArgumentException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.invalidArgument, message, statusCode: statusCode, reason: reason);
}

/// Storage's `failedPrecondition`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.failedPrecondition. Removed in the next major version.')
final class StorageFailedPreconditionException extends WincheStorageException {
  StorageFailedPreconditionException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.failedPrecondition, message, statusCode: _statusOf(details));

  StorageFailedPreconditionException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.failedPrecondition, message, statusCode: statusCode, reason: reason);
}

/// Storage's `deadlineExceeded`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.deadlineExceeded. Removed in the next major version.')
final class StorageDeadlineExceededException extends WincheStorageException {
  StorageDeadlineExceededException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.deadlineExceeded, message, statusCode: _statusOf(details));

  StorageDeadlineExceededException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.deadlineExceeded, message, statusCode: statusCode, reason: reason);
}

/// Storage's `unavailable`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.unavailable. Removed in the next major version.')
final class StorageUnavailableException extends WincheStorageException {
  StorageUnavailableException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.unavailable, message, statusCode: _statusOf(details));

  StorageUnavailableException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.unavailable, message, statusCode: statusCode, reason: reason);
}

/// Storage's `cancelled`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.cancelled. Removed in the next major version.')
final class StorageCancelledException extends WincheStorageException {
  StorageCancelledException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.cancelled, message, statusCode: _statusOf(details));

  StorageCancelledException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.cancelled, message, statusCode: statusCode, reason: reason);
}

/// Storage's `internal`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.internal. Removed in the next major version.')
final class StorageInternalException extends WincheStorageException {
  StorageInternalException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.internal, message, statusCode: _statusOf(details));

  StorageInternalException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.internal, message, statusCode: statusCode, reason: reason);
}

/// Storage's `unknown`.
@Deprecated('Catch WincheStorageException and check code == WincheErrorCode.unknown. Removed in the next major version.')
final class StorageUnknownException extends WincheStorageException {
  StorageUnknownException(String message, [Map<String, Object?>? details])
    : super(WincheErrorCode.unknown, message, statusCode: _statusOf(details));

  StorageUnknownException._(String message, int? statusCode, String? reason)
    : super(WincheErrorCode.unknown, message, statusCode: statusCode, reason: reason);
}
