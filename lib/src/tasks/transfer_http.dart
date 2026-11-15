import 'dart:async';

import 'package:winche_core/winche_core.dart';

/// The client transfers use for signed links when none is given: they carry
/// no token, so they need no app. Shared, so its connections are pooled.
final WincheHttp defaultTransferHttp = WincheHttp.standalone();

/// How long one transfer may take to be answered. Long: the server answers an
/// upload only after its last byte, which a slow connection can take hours over.
const transferTimeout = Duration(hours: 6);

/// Abandons the request it was handed to. One per attempt.
final class TransferAbort {
  final _fired = Completer<void>();

  /// For [WincheRequest.abortTrigger].
  Future<void> get trigger => _fired.future;

  /// Whether [abort] was called.
  bool get isAborted => _fired.isCompleted;

  /// Abandons the request.
  void abort() {
    if (!_fired.isCompleted) _fired.complete();
  }
}

/// Whether [error] is a request abandoned through [TransferAbort].
bool isTransferAborted(Object error) => error is WincheHttpException && error.code == WincheErrorCode.cancelled;

/// Whether [error] is a network failure with no answer from the server: no
/// connection, a dropped one, or no answer in time.
bool isTransferNetworkFailure(Object error) =>
    error is WincheHttpException && error.status == null && error.code != WincheErrorCode.cancelled;
